## no critic (RequireUseStrict)
package Tapper::MCP::Scheduler::PrioQueue;
BEGIN {
  $Tapper::MCP::Scheduler::PrioQueue::AUTHORITY = 'cpan:AMD';
}
{
  $Tapper::MCP::Scheduler::PrioQueue::VERSION = '4.0.2';
}
# ABSTRACT: Object for test queue abstraction

        use 5.010;
        use Moose;

        use Tapper::Model 'model';
        use aliased 'Tapper::Schema::TestrunDB::Result::TestrunScheduling';

        sub _max_seq {
                my ($self) = @_;

                my $job_with_max_seq = model('TestrunDB')->resultset('TestrunScheduling')->search
                    (
                     { prioqueue_seq => { '>', 0 } },
                     {
                      select => [ { max => 'prioqueue_seq' } ],
                      as     => [ 'max_seq' ], }
                    )->first;
                return $job_with_max_seq->get_column('max_seq')
                  if $job_with_max_seq and defined $job_with_max_seq->get_column('max_seq');
                return 0;
        }

        sub add {
                my ($self, $job, $is_subtestrun) = @_;

                my $max_seq = $self->_max_seq;
                $job->prioqueue_seq($max_seq + 1);
                $job->update;
        }

        sub get_testrequests {
                my ($self) = @_;

                no strict 'refs'; ## no critic (ProhibitNoStrict)
                my $testrequests_rs = model('TestrunDB')->resultset('TestrunScheduling')->search
                    ({
                      prioqueue_seq => { '>', 0 }
                     },
                     {
                      order_by => 'prioqueue_seq'
                     }
                    );
                return $testrequests_rs;
        }

        sub get_first_fitting {
                my ($self, $free_hosts) = @_;

                my $jobs = $self->get_testrequests;
                while (my $job = $jobs->next()) {
                        if (my $host = $job->fits($free_hosts)) {
                                $job->host_id ($host->id);

                                if ($job->testrun->scenario_element) {
                                        $job->testrun->scenario_element->is_fitted(1);
                                        $job->testrun->scenario_element->update();
                                }

                                return $job;
                        }
                }
                return;
        }

1;



=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Scheduler::PrioQueue - Object for test queue abstraction

=head1 SYNOPSIS

=head1 FUNCTIONS

=head2 get_test_request

Get a testrequest for one of the free hosts provided as parameter.

@param array ref - list of hostnames

@return success               - Job
@return no fitting tr found   - 0

=head2 produce

Call the producer method associated with this object.

@param string - hostname

@return success - test run id
@return error   - exception

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut


__END__

