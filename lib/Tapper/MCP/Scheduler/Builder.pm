## no critic (RequireUseStrict)
package Tapper::MCP::Scheduler::Builder;
BEGIN {
  $Tapper::MCP::Scheduler::Builder::AUTHORITY = 'cpan:TAPPER';
}
{
  $Tapper::MCP::Scheduler::Builder::VERSION = '4.1.2';
}
# ABSTRACT: Generate Testruns

        use Moose;


        sub build {
                my ($self, $hostname) = @_;

                print "We are we are: The youth of the nation";
                return 0;
        }

1;

__END__
=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Scheduler::Builder - Generate Testruns

=head1 FUNCTIONS

=head2 build

Create files needed for a testrun and put it into db.

@param string - hostname

@return success - testrun id

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut

