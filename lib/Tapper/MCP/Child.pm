package Tapper::MCP::Child;
BEGIN {
  $Tapper::MCP::Child::AUTHORITY = 'cpan:TAPPER';
}
{
  $Tapper::MCP::Child::VERSION = '4.1.2';
}
# ABSTRACT: Control one specific testrun on MCP side

use 5.010;
use strict;
use warnings;

use Hash::Merge::Simple qw/merge/;
use List::Util qw(min max);
use Moose;
#use UNIVERSAL;
use YAML::Syck;

use Tapper::MCP::Net;
use Tapper::MCP::Config;
use Tapper::Model 'model';
use Tapper::MCP::State;
use Devel::Backtrace;

use constant BUFLEN     => 1024;
use constant ONE_MINUTE => 60;

extends 'Tapper::MCP::Control';
with 'Tapper::MCP::Net::TAP';

has state    => (is => 'rw');
has mcp_info => (is => 'rw');
has rerun    => (is => 'rw', default => 0);


sub get_messages
{
        my ($self, $timeout) = @_;
        $timeout //= 0; # get rid of warning;
        my $end_time = time() + $timeout;

        my $messages;
        while () {
                $messages = $self->testrun->message;
                last if ($messages and $messages->count) or time() > $end_time;
                sleep 1 unless $ENV{HARNESS_ACTIVE};
        }
        return $messages;
}


sub wait_for_testrun
{
        my ($self) = @_;

        my $timeout_span = $self->state->get_current_timeout_span();
        my $error;

 MESSAGE:
        while (1) {
                my $msg = $self->get_messages($timeout_span);
                ($error, $timeout_span) = $self->state->update_state($msg);
                if ($error) {
                        last MESSAGE if $self->state->testrun_finished;
                }
        }
}



sub generate_configs
{

        my ($self, $hostname ) = @_;
        my $retval;


        my $mcpconfig = Tapper::MCP::Config->new($self->testrun);
        $self->log->debug("Create install config for $hostname");
        my $config   = $mcpconfig->create_config();
        return $config if not ref($config) eq 'HASH';

        $retval = $mcpconfig->write_config($config, "$hostname-install");
        return $retval if $retval;

        if ($config->{autoinstall} or $mcpconfig->mcp_info->skip_install) {
                my $common_config = $mcpconfig->get_common_config();
                $common_config->{hostname} = $hostname; # allows guest systems to know their host system name

                my $testconfigs = $mcpconfig->get_test_config();
                return $testconfigs if not ref $testconfigs eq 'ARRAY';

                for (my $i=0; $i<= $#{$testconfigs}; $i++ ) {
                        my $prc_config = merge($common_config, $testconfigs->[$i]);
                        $prc_config->{guest_number} = $i;
                        my $suffix = "test-prc$i";

                        $retval = $mcpconfig->write_config($prc_config, "$hostname-$suffix");
                        return $retval if $retval;
                }
        }
        $self->mcp_info($mcpconfig->mcp_info());
        $config->{hostname} = $hostname;
        return $config;
}



sub report_mcp_results
{
        my ($self) = @_;

        my $headerlines = $self->mcp_headerlines();
        my $mcp_results = $self->state->state_details->results();
        my ($error, $report_id) = $self->tap_report_send($mcp_results, $headerlines);
        if ($error) {
                $self->log->error('Can not send TAP report for testrun '.$self->testrun->id.
                                  " on ".$self->cfg->{hostname}.": $report_id");
                return;
        }

        my $prc_count = $self->state->state_details->prc_count;
 PRC_RESULT:
        for (my $prc_number = 0; $prc_number < $prc_count; $prc_number++)
        {
                my $prc_results = $self->state->state_details->prc_results($prc_number);
                next PRC_RESULT if not (ref($prc_results) eq 'ARRAY' and @$prc_results);
                $headerlines = $self->prc_headerlines($prc_number);
                $self->tap_report_send($prc_results, $headerlines);
        }
        $self->upload_files($report_id, $self->testrun->id );
}


sub handle_error
{
        my ($self, $error_msg, $error_comment) = @_;
        my $headerlines = $self->mcp_headerlines();
        my $results     = [{ error => 1, msg => $error_msg, comment => $error_comment}];
        my ($error, $report_id) = $self->tap_report_send($results, $headerlines);
        $self->upload_files($report_id, $self->testrun->id);
        return $error;
}


sub start_testrun
{
        my ($self, $hostname, $config) = @_;

        my $net    = Tapper::MCP::Net->new();
        $net->cfg->{testrun_id} = $self->testrun->id;
        given(lc($self->mcp_info->test_type)){
                when('simnow'){
                        $self->log->debug("Starting Simnow on $hostname");
                        my $simnow_retval = $net->start_simnow($hostname);
                        return $self->handle_error("Starting simnow", $simnow_retval) if $simnow_retval;
                }
                when('ssh') {
                        $self->log->debug("Starting SSH testrun on $hostname");
                        my $ssh_retval;
                        if ($config->{client_package}) {
                                $ssh_retval = $net->install_client_package($hostname, $config->{client_package});
                                return $self->handle_error("Starting Tapper on testmachine with SSH", $ssh_retval)
                                  if $ssh_retval;
                        }

                        $ssh_retval = $net->start_ssh($hostname);
                        if ($ssh_retval) {
                                $self->handle_error("Starting Tapper on testmachine with SSH", $ssh_retval);
                                return ("Starting Tapper on testmachine with SSH failed: $ssh_retval");
                        }
                }
                when('local') {
                        $self->log->debug("Starting LOCAL testrun on $hostname");
                        my $local_retval;
                        my $path_to_config = $self->mcp_info->skip_install ?
                          $config->{paths}{localdata_path}."/$hostname-test-prc0" :
                            $config->{paths}{localdata_path}."/$hostname-install";
                        $local_retval = $net->start_local($path_to_config);
                        if ($local_retval) {
                                $self->handle_error("Starting Tapper on testmachine with SSH", $local_retval);
                                return ("Starting Tapper on testmachine with SSH failed: $local_retval");
                        }
                }
                default {
                        $self->log->debug("Write grub file for $hostname");
                        my $grub_retval = $net->write_grub_file($hostname, $config->{installer_grub});
                        return $self->handle_error("Writing grub file", $grub_retval) if $grub_retval;

                        $self->log->debug("rebooting $hostname");
                        my $reboot_retval = $net->reboot_system($hostname);
                        if ($reboot_retval) {
                                $self->handle_error("Booting machine", $reboot_retval);
                                return $reboot_retval;
                        }

                        my ($error, $report) = $net->hw_report_create($self->testrun->id);
                        if ($error) {
                                $self->log->error($report);
                        } else {
                                $self->tap_report_away($report);
                        }
                }
        }

        return 0;
}


sub runtest_handling
{

        my  ($self, $hostname, $revive) = @_;

        $0 = "tapper-mcp-child-".$self->testrun->id;
        $SIG{USR1} = sub {
                local $SIG{USR1}  = 'ignore'; # make handler reentrant, don't handle signal twice
                my $backtrace = Devel::Backtrace->new(-start=>2, -format => '%I. %s');
                open my $fh, ">>", '/tmp/tapper-mcp-child-'.$self->testrun->id;
                print $fh $backtrace;
                close $fh;
        };

        my $net    = Tapper::MCP::Net->new();
        $net->cfg->{testrun_id} = $self->testrun->id;

        my $config = $self->generate_configs($hostname);
        return $self->handle_error("Generating configs", $config) if ref $config ne 'HASH';

        if ($config->{testrun_stop}) {
                my $host = model('TestrunDB')->resultset('Host')->search({name => $hostname});
                $host->active(0);
                $host->comment($host->comment."(deactivated by testrun".$self->testrun->id.")");
                $host->update;
        }

        $self->log->info("Reviving testrun ",$self->testrun->id) if $revive;
        $self->state(Tapper::MCP::State->new(testrun_id => $self->testrun->id, cfg => $config));
        $self->state->state_init($self->mcp_info->get_state_config, $revive );

        if ($self->state->compare_given_state('reboot_install') == 1) { # before reboot_install?
                my $error = $self->start_testrun($hostname, $config);
                return $error if $error;

                my $message = model('TestrunDB')->resultset('Message')->new
                  ({
                    message => {state => 'takeoff',
                                skip_install => $self->mcp_info->skip_install,
                               },
                    testrun_id => $self->testrun->id,
                   });
                $message->insert;
                $self->state->update_state($message);
        }

        $self->log->debug('waiting for test to finish');
        $self->wait_for_testrun();
        $self->report_mcp_results();
        return 0;

}

1;


__END__
=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Child - Control one specific testrun on MCP side

=head1 SYNOPSIS

 use Tapper::MCP::Child;
 my $client = Tapper::MCP::Child->new($testrun_id);
 $child->runtest_handling($system);

=head1 FUNCTIONS

=head2 get_messages

Read all pending messages from database. Try no more than timeout seconds

@param int - timeout

@return success - Resultset class countaining all available messages
@return timeout - Resultset class countaining zero messages

=head2 wait_for_testrun

Wait for the current testrun and update state based on messages.

@return hash { report_array => reference to report array, prc_state => $prc_state }

=head2 generate_configs

@param string   - hostname
@param int      - port number of server

@return success - config hash
@return error   - string

=head2 report_mcp_results

Send TAP reports of MCP results in general and the results collected for each PRC.

@param Tapper::MC::Net object

=head2 handle_error

Sends a tap report because an error occured.

@param string - error string

@return error string

=head2 start_testrun

Start Installer on testmachine based on the type of testrun.

@param string   - host name
@param hash ref - config

@return success - 0
@return error   - error string

=head2 runtest_handling

Start testrun and wait for completion.

@param string - system name
@param bool   - revive mode?

@return success - 0
@return error   - error string

=head1 AUTHOR

AMD OSRC Tapper Team, C<< <tapper at amd64.org> >>

=head1 BUGS

None.

=head1 SUPPORT

You can find documentation for this module with the perldoc command.

 perldoc Tapper

=head1 ACKNOWLEDGEMENTS

=head1 COPYRIGHT & LICENSE

Copyright 2008-2011 AMD OSRC Tapper Team, all rights reserved.

This program is released under the following license: freebsd

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut

