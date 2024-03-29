## no critic (RequireUseStrict)
package Tapper::MCP::Master;
BEGIN {
  $Tapper::MCP::Master::AUTHORITY = 'cpan:TAPPER';
}
{
  $Tapper::MCP::Master::VERSION = '4.1.2';
}
# ABSTRACT: Wait for new testruns and start a new child when needed

        use 5.010;
        use Moose;
        use parent "Tapper::MCP";
        use Devel::Backtrace;
        use File::Path;
        use IO::Select;
        use IO::Handle;
        use Log::Log4perl;
        use POSIX ":sys_wait_h";
        use Try::Tiny;
        use UNIVERSAL;
        use constant HARNESS_ACTIVE => $ENV{HARNESS_ACTIVE};

        use Tapper::Cmd::Testrun;
        use Tapper::MCP::Child;
        use Tapper::MCP::Net;
        use Tapper::MCP::Scheduler::Controller;
        use Tapper::Model 'model';


        has dead_child   => (is => 'rw', default => 0);


        has child        => (is => 'rw', isa => 'HashRef', default => sub {{}});


        has consolefiles => (is => 'rw', isa => 'ArrayRef', default => sub {[]});



        has readset      => (is => 'rw');


        has scheduler    => (is => 'rw', isa => 'Tapper::MCP::Scheduler::Controller');


sub BUILD
{
        my $self = shift;
        $self->scheduler(Tapper::MCP::Scheduler::Controller->new());
}



        sub set_interrupt_handlers
        {
                my ($self) = @_;
                $SIG{CHLD} = sub {
                        $self->dead_child($self->dead_child + 1);
                };

                # give me a stack trace when ^C
                $SIG{INT} = sub {
                        $SIG{INT}  = 'IGNORE'; # make handler reentrant, don't handle signal twice

                        # stop all children
                        $SIG{CHLD} = 'IGNORE';
                        foreach my $this_child (keys %{$self->child}) {
                                kill 15, $self->child->{$this_child}->{pid};
                        }

                        my $backtrace = Devel::Backtrace->new(-start=>2, -format => '%I. %s');
                        print $backtrace;

                        exit -1;
                };
                return 0;
        }


        sub console_open
        {
                my ($self, $system, $testrunid) = @_;
                return "Incomplete data given to function console_open" if not $system and defined($testrunid);

                my $path = $self->cfg->{paths}{output_dir}."/$testrunid/";
                File::Path::mkpath($path, {error => \my $retval}) if not -d $path;
                foreach my $diag (@$retval) {
                        my ($file, $message) = each %$diag;
                        return "general error: $message\n" if $file eq '';
                        return "Can't create $file: $message";
                }

                my $net = Tapper::MCP::Net->new();
                my $console;
                eval{
                        local $SIG{ALRM} = sub { die 'Timeout'; };
                        alarm (5);
                        $console = $net->conserver_connect($system);
                };
                alarm 0;
                return "Unable to open console for $system after 5 seconds" if $@;

                return $console if not ref $console eq 'IO::Socket::INET';
                $console->blocking(0);
                $self->readset->add($console);


                $path .= "console";
                my $fh;
                open($fh,">>",$path) or do {
                        $self->readset->remove($console);
                        close $console;
                        return "Can't open console log file $path for test on host $system:$!";
                };
                $self->consolefiles->[$console->fileno()] = $fh;
                return $console;
        }



        sub console_close
        {
                my ($self, $console) = @_;
                return 0 if not ($console and $console->can('fileno'));
                close $self->consolefiles->[$console->fileno()]
                    or return "Can't close console file:$!";
                $self->consolefiles->[$console->fileno()] = undef;
                $self->readset->remove($console);
                my $net = Tapper::MCP::Net->new();
                $net->conserver_disconnect($console);
                alarm 0;
                return 0;
        }


        sub handle_dead_children
        {
                my ($self) = @_;
        CHILD: while ($self->dead_child) {
                        $self->log->debug("Number of dead children is ".$self->dead_child);
                        my $dead_pid = waitpid(-1, WNOHANG);  # don't use wait(); qx() sends a SIGCHLD and increases $self->deadchild, but wait() for the return value and thus our wait would block
                CHILDREN_CHECK: foreach my $this_child (keys %{$self->child})
                        {
                                if ($self->child->{$this_child}->{pid} == $dead_pid) {
                                        $self->log->debug("$this_child finished");
                                        $self->scheduler->mark_job_as_finished( $self->child->{$this_child}->{job} );
                                        $self->console_close( $self->child->{$this_child}->{console} );
                                        delete $self->child->{$this_child};
                                        last CHILDREN_CHECK;
                                }
                        }
                        $self->dead_child($self->dead_child - 1);
                }
        }



        sub consolelogfrom
        {
                my ($self, $handle) = @_;
                my ($buffer, $readsize);
                my $timeout = 2;
                my $maxread = 1024; # XXX configure
                my $errormsg;

                eval {
                        local $SIG{ALRM} = sub { die "Timeout ($timeout) reached" };
                        alarm $timeout;
                        $readsize  = sysread($handle, $buffer, $maxread);
                };
                alarm 0;

                $errormsg = "Error while reading console: $@" if $@;
                $errormsg = "Can't read from console: $!"     if not defined $readsize;

                my $file    = $self->consolefiles->[$handle->fileno()];
                return "Can't get console file:$!" if not defined $file;

                $buffer  .= "*** Tapper: $errormsg ***" if $errormsg;

                $readsize = syswrite($file, $buffer);
                return "Can't write console data to file :$!" if not defined $readsize;

                return $errormsg if $errormsg;
                return 0;
        }


        sub notify_event
        {
                my ($self, $event, $message) = @_;
                try
                {
                        my $new_event = model('ReportsDB')->resultset('NotificationEvent')->new({type => $event,
                                                                                                 message => $message,
                                                                                                });
                        $new_event->insert();
                } catch {
                        $self->log->error("Unable notify user of event $event: $_");
                };

                return;
        }



        sub run_due_tests
        {
                my ($self, $job, $revive) = @_;
                $self->log->debug('run_due_test');

                my $system = $job->host->name;
                my $id = $job->testrun->id;

                $self->log->info("start testrun $id on $system");
                # check if this system is already active, just for error handling
                $self->handle_dead_children() if $self->child->{$system};

                $self->scheduler->mark_job_as_running($job) unless $revive;

                my $pid = fork();
                die "fork failed: $!" if (not defined $pid);

                # hello child
                if ($pid == 0) {

                        my $child = Tapper::MCP::Child->new( $id );
                        my $retval;
                        eval {
                                $retval = $child->runtest_handling( $system, $revive );
                        };
                        $retval = $@ if $@;

                        $self->notify_event('testrun_finished', {testrun_id => $id});

                        if ( ($retval or $child->rerun) and $job->testrun->rerun_on_error) {
                                my $cmd  = Tapper::Cmd::Testrun->new();
                                my $new_id;
                                eval {
                                        $new_id = $cmd->rerun($id, {rerun_on_error => $job->testrun->rerun_on_error - 1});
                                };
                                if ($@) {
                                        $self->log->error($@);
                                } else {
                                        $self->log->debug("Restarted testrun $id with new id $new_id because ".
                                                          "an error occurred and rerun_on_error was ".
                                                          $job->testrun->rerun_on_error);
                                }
                        }
                        if ($retval) {
                                $self->log->error("Testrun $id ($system) error occurred: $retval");
                        } else {
                                $self->log->info("Testrun $id ($system) finished successfully");
                        }
                        exit 0;
                } else {
                        my $console = $self->console_open($system, $id);

                        if (ref($console) eq 'IO::Socket::INET') {
                                $self->child->{$system}->{console}  = $console;
                        } else {
                                $self->log->info("Can not open console on $system: $console");
                        }

                        $self->child->{$system}->{pid}      = $pid;
                        $self->child->{$system}->{test_run} = $id;
                        $self->child->{$system}->{job}      = $job;
                }
                return 0;

        }



        sub runloop
        {
                my ($self, $lastrun) = @_;
                my $timeout          = $lastrun + $self->cfg->{times}{poll_intervall} - time();
                $timeout = 0 if $timeout < 0;

                my @ready;
                # if readset is empty, can_read immediately returns with an empty
                # array; this makes runloop a CPU burn loop
                if ($self->readset->count) {
                        @ready = $self->readset->can_read( $timeout );
                } else {
                        sleep $timeout;
                }
                $self->handle_dead_children() if $self->dead_child;

        HANDLE:
                foreach my $handle (@ready) {
                        if (not $handle->opened()) {
                                $self->readset->remove($handle);
                                next HANDLE;
                        }

                        my $retval = $self->consolelogfrom($handle);
                        if ($retval) {
                                $self->log->error($retval);
                                $self->console_close($handle);
                        }
                }

                if (($timeout <= 0) or (not @ready)) {
                        my @jobs;
                        my $pid = open(my $fh, "-|");
                        if ($pid == 0) {
                                my @jobs = $self->scheduler->get_next_job;
                                print join ",", map {$_->id} @jobs;
                                exit;
                        } else {
                                my $ids_joined = <$fh>;
                                {
                                        no warnings 'uninitialized'; # we may not have ids_joined when no test is due
                                        foreach my $next_id (split ',', $ids_joined) {
                                                push @jobs, model('TestrunDB')->resultset('TestrunScheduling')->find($next_id);
                                        }
                                }
                        }

                        foreach my $job (@jobs) {
                                # (WORKAROUND) try to avoid to
                                # children being started close
                                # to each other and trying to
                                # reset simulataneously
                                sleep 2 unless HARNESS_ACTIVE;
                                $self->run_due_tests($job);
                        }
                        $lastrun = time();
                }

                return $lastrun;
        }



        sub prepare_server
        {
                my ($self) = @_;
                Log::Log4perl->init($self->cfg->{files}{log4perl_cfg});
                # these sets are used by select()
                my $select = IO::Select->new();
                return "Can't create select object:$!" if not $select;
                $self->readset ($select);
                return "Can't create select object:$!" if not $select;

                return 0;
        }


sub revive_children
{
        my ($self) = @_;
        my $jobs = model->resultset('TestrunScheduling')->running;
        foreach my $job ($jobs->all) {
                $self->run_due_tests($job, "revive");
        }
}




        sub run
        {
                my ($self) = @_;
                $self->set_interrupt_handlers();
                $self->prepare_server();
                $self->revive_children();
                my $lastrun = time();
                while (1) {
                         $lastrun = $self->runloop($lastrun);
                }

        }

1;

__END__
=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Master - Wait for new testruns and start a new child when needed

=head1 SYNOPSIS

 use Tapper::MCP::Master;
 my $mcp = Tapper::MCP::Master->new();
 $mcp->run();

=head1 Attributes

=head2 dead_child

Number of pending dead child processes.

=head2 child

Contains all information about all child processes.

=head2 consolefiles

Output files for console logs ordered by file descriptor number.

=head2 readset

IO::Select object containing all opened console file handles.

=head2

Associated Scheduler object.

=head1 FUNCTIONS

=head2 set_interrupt_handlers

Set interrupt handlers for important signals. No parameters, no return values.

@return success - 0

=head2 console_open

Open console connection for given host and appropriate console log output file
for the testrun on host. Returns console on success or an error string for
failure.

@param string - system name
@param int    - testrun id

@retval success - IO::Socket::INET
@retval error   - error string

=head2 console_close

Close a given console connection.

@param IO::Socket::INET - console connection socket

@retval success - 0
@retval error   - error string

=head2 handle_dead_children

Each test run is handled by a child process. All information needed for
communication with this child process is kept in $self->child. Reset all these
information when the test run is finished and the child process ends.

=head2 consolelogfrom

Read console log from a handle and write it to the appropriate file.

@param file handle - read from this handle

@retval success - 0
@retval error   - error string

=head2 notify_event

Inform the notification framework that an event occured in MCP.

@param string - event name
@param hash ref - message

=head2 run_due_tests

Run the tests that are due.

@param TestrunScheduling - job to run
@param boolean - are we in revive mode?

@retval success - 0
@retval error   - error string

=head2 runloop

Main loop of this module. Checks for new tests and runs them. The looping
itself is put outside of function to allow testing.

=head2 prepare_server

Create communication data structures used in MCP.

@return

=head2 revive_children

Restart the children that were running before MCP was shut
down/crashed. The function expects no parameters and has no return
values.

=head2 run

Set up all needed data structures then wait for new tests.

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut

