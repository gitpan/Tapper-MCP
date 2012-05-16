## no critic (RequireUseStrict)
package Tapper::MCP::Scheduler::Algorithm::DummyAlgorithm;
BEGIN {
  $Tapper::MCP::Scheduler::Algorithm::DummyAlgorithm::AUTHORITY = 'cpan:AMD';
}
{
  $Tapper::MCP::Scheduler::Algorithm::DummyAlgorithm::VERSION = '4.0.1';
}
# ABSTRACT: Dummy algorithm for testing

        use 5.010;
        use Moose::Role;
        requires 'queues';

        has current_queue => (is => "rw");

        sub get_new_pos {
                my ($self, $Q) = @_;

                my @Q = @$Q;
                my %Q = map { $Q[$_] => $_ } 0..$#Q;

                if (not $self->current_queue) {
                        return 0;
                }

                my $cur_name = $self->current_queue->name;
                my $new_pos = (($Q{$cur_name} || 0) + 1) % @Q;
                return $new_pos;

        }

        sub lookup_next_queue {
                my ($self, $queues) = @_;

                my @Q = sort keys %{$queues};
                my $pos = $self->get_new_pos(\@Q);

                return $self->queues->{$Q[$pos]};
        }

        sub get_next_queue {
                my ($self) = @_;

                my @Q = sort keys %{$self->queues};
                my $pos = $self->get_new_pos(\@Q);

                my $name = $Q[$pos];
                $self->update_queue($self->queues->{$name});
                return $self->current_queue;
        }

        sub update_queue {
                my ($self, $Q) = @_;

                $self->current_queue( $self->queues->{$Q->name} );
                return 0;
        }

1; # End of Tapper::MCP::Scheduler::Algorithm::WFQ



=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Scheduler::Algorithm::DummyAlgorithm - Dummy algorithm for testing

=head1 SYNOPSIS

Algorithm that returns queues in order it received it.

=head1 FUNCTIONS

=head2 get_next_queue

Evaluate which client has to be scheduled next.

@return success - client name;

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut


__END__

