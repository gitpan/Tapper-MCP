## no critic (RequireUseStrict)
package Tapper::MCP::Scheduler::Controller;
BEGIN {
  $Tapper::MCP::Scheduler::Controller::AUTHORITY = 'cpan:AMD';
}
{
  $Tapper::MCP::Scheduler::Controller::VERSION = '4.0.1';
}
# ABSTRACT: Main class of the scheduler

        use 5.010;
        use Moose;
        use base "Tapper::Base";
        use Tapper::Model 'model';
        use aliased 'Tapper::MCP::Scheduler::Algorithm';
        use aliased 'Tapper::MCP::Scheduler::PrioQueue';
        use Tapper::MCP::Net;

        has hostlist  => (is => 'rw', isa => 'ArrayRef');
        has prioqueue => (is => 'rw', isa => PrioQueue, default => sub { PrioQueue->new });
        has algorithm => (is => 'rw',
                          isa => 'Tapper::MCP::Scheduler::Algorithm',
                          default => sub {
                                          Algorithm->new_with_traits
                                          (
                                           traits => ['Tapper::MCP::Scheduler::Algorithm::WFQ']
                                          );
                                         }
                         );

        has testrun   => (is => 'rw');
        has cfg       => (is => 'ro', default => sub {{}});

        with "Tapper::MCP::Net::TAP";


        sub toggle_bandwith_color {
                my ($self, $free_hosts, $queue) = @_;

                return 0 if $queue->queued_testruns->count == 0;
                foreach my $free_host( map {$_->{host} } @$free_hosts) {
                        if ($free_host->queuehosts->count){
                                QUEUE_CHECK:
                                {
                                        foreach my $queuehost($free_host->queuehosts->all) {
                                                return 0 if $queuehost->queue->id == $queue->id;
                                        }
                                }
                        } else {
                                return 0;
                        }
                }
                return 1;
        }



        sub get_next_job {
                my ($self, %args) = @_;

                my ($queue, $job);

                do {{

                        my $free_hosts = Tapper::Model::free_hosts_with_features();
                        return if not ($free_hosts and @$free_hosts);


                        my $queues = model('TestrunDB')->resultset('Queue')->official_queuelist();

                        my $white_bandwith=1;  # chosen queue was first choice

                QUEUE:
                        while (1) {
                                # ask prioqueue everytime when in loop because new priority jobs
                                # that got into DB between to loop runs still have highest priority
                                last QUEUE if $job = $self->prioqueue->get_first_fitting($free_hosts);


                                my $queue = $self->algorithm->lookup_next_queue($queues);
                                return () unless $queue;
                                if ($job = $queue->get_first_fitting($free_hosts)) {
                                        if ($job->auto_rerun) {
                                                $job->testrun->rerun;
                                        }
                                        if ($job->testrun->scenario_element) {
                                        ELEMENT:
                                                foreach my $element ($job->testrun->scenario_element->peer_elements) {
                                                        my $peer_job = $element->testrun->testrun_scheduling;
                                                        next ELEMENT if $peer_job->id == $job->id;
                                                        $self->prioqueue->add($peer_job);
                                                }
                                        }
                                        $self->algorithm->update_queue($job->queue) if $white_bandwith;
                                        last QUEUE;
                                } else {
                                        delete $queues->{$queue->name};
                                        $white_bandwith=0 if $self->toggle_bandwith_color($free_hosts, $queue);

                                }
                                last QUEUE if not %$queues;
                        }

                        if ($job and $job->testrun->scenario_element) {
                                $self->mark_job_as_running($job);
                                if ($job->testrun->scenario_element->peers_need_fitting > 0) {
                                        # do not return this job already
                                        $job = undef;
                                        next;
                                } else {
                                        return map{$_->testrun->testrun_scheduling} $job->testrun->scenario_element->peer_elements->all;
                                }
                        }
                }} while (not $job and $args{try_until_found});

                return $job || () ;
        }

        sub mark_job_as_running {
                my ($self, $job) = @_;

                $job->testrun->starttime_testrun(model('TestrunDB')->storage->datetime_parser->format_datetime(DateTime->now));
                $job->testrun->update();
                $job->mark_as_running;
        }

        sub mark_job_as_finished {
                my ($self, $job) = @_;

                $job->testrun->endtime_test_program(model('TestrunDB')->storage->datetime_parser->format_datetime(DateTime->now));
                $job->testrun->update();
                $job->mark_as_finished;
        }

1; # End of Tapper::MCP::Scheduler::Controller

__END__
=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Scheduler::Controller - Main class of the scheduler

=head2

Check whether we need to change from scheduling white bandwidth to black bandwidth.

@return black - 1
@return white - 0

=head2 get_next_job

Pick a testrequest and prepare it for execution. Returns 0 if not testrequest
fits any of the free hosts.

@param ArrayRef - array of host objects associated to hosts with no current test

@return success   - job object
@return no job    - 0

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut

