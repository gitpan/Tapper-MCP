# critic (RequireUseStrict)
package Tapper::MCP::Scheduler::PrioQueue;
BEGIN {
  $Tapper::MCP::Scheduler::PrioQueue::AUTHORITY = 'cpan:AMD';
}
{
  $Tapper::MCP::Scheduler::PrioQueue::VERSION = '4.1.0';
}
 # ABSTRACT: Object for test queue abstraction

use 5.010;
use Moose;

use Tapper::Model 'model';
use aliased 'Tapper::Schema::TestrunDB::Result::TestrunScheduling';


has testrunschedulings => (is => 'ro',
                           lazy => 1,
                           default => sub {
                                   my ($self) = shift;
                                   my @return_jobs;
                                   my $jobs = model('TestrunDB')->resultset('TestrunScheduling')->search({prioqueue_seq => { '>', 0}, status => 'schedule'}, {order_by => 'prioqueue_seq'});
                                   $jobs->result_class('DBIx::Class::ResultClass::HashRefInflator');
                                   my $obj_builder = Tapper::MCP::Scheduler::ObjectBuilder->instance;

                                   while (my $this_job = $jobs->next) {
                                           $this_job->{queue} = $self;
                                           push @return_jobs, $obj_builder->new_job(%{$this_job});
                                   }
                                   return \@return_jobs;
                           });


sub _max_seq {
        my ($self) = @_;

        my $job_with_max_seq = model('TestrunDB')->resultset('TestrunScheduling')->search
          (
           {
            prioqueue_seq => { '>', 0 } },
           {
            select => [ { max => 'prioqueue_seq' } ],
            as     => [ 'max_seq' ],
            rows   => 1,
           }
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
        my %job_hash = $job->get_inflated_columns;
        my $obj_builder = Tapper::MCP::Scheduler::ObjectBuilder->instance;
        push @{$self->testrunschedulings}, $obj_builder->new_job(%job_hash);
}

sub get_first_fitting {
        my ($self, $free_hosts) = @_;

        foreach my $job (@{$self->testrunschedulings}) {
                if (my $host = $job->fits($free_hosts)) {
                        my $db_job = model('TestrunDB')->resultset('TestrunScheduling')->find($job->{id});
                        $db_job->host_id ($host->id);
                        $db_job->update;
                        if ($db_job->testrun->scenario_element) {
                                $db_job->testrun->scenario_element->is_fitted(1);
                                $db_job->testrun->scenario_element->update();
                        }

                        return $db_job;
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

