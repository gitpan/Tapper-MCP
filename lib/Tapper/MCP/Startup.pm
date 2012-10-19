package Tapper::MCP::Startup;
BEGIN {
  $Tapper::MCP::Startup::AUTHORITY = 'cpan:AMD';
}
{
  $Tapper::MCP::Startup::VERSION = '4.1.0';
}
# ABSTRACT: the central "Master Control Program" starter

use 5.010;

use strict;
use warnings;

use Tapper::MCP::Master;
use Moose;

no strict 'refs'; ## no critic (ProhibitNoStrict)


has master  => (is          => 'rw',
                default     => sub { new Tapper::MCP::Master ( pidfile => '/tmp/tapper_mcp_master.pid' ) }
               );

has servers => ( is         => 'rw',
                 isa        => 'ArrayRef',
                 auto_deref => 1,
                     );

sub start   { my ($self) = @_; $_->start   foreach $self->servers }
sub status  { my ($self) = @_; $_->status  foreach $self->servers }
sub restart { my ($self) = @_; $_->restart foreach $self->servers }
sub stop    { my ($self) = @_; $_->stop    foreach $self->servers }

around 'new' => sub {
                     my ($new, @args) = @_;

                     my $self = $new->(@args);
                     $self->set_servers;
                     return $self;
                    };


sub set_servers
{
        my ($self) = @_;
        $self->servers ([
                         $self->master,
                        ]);
}


sub run
{
        my ($self) = @_;
        my ($command) = @ARGV;
        return unless $command && grep /^$command$/, qw(start status restart stop);
        local @ARGV;   # cleaner approach than changing @ARGV
        $self->$command;
}

1;

__END__
=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Startup - the central "Master Control Program" starter

=head1 SYNOPSIS

 use Tapper::MCP::Startup qw(:all);

=head1 FUNCTIONS

=for method Declares a method.

=for start Starts all registered daemons.

=for stop Stops all registered daemons.

=for restart Restarts all registered daemons.

=for status Prints status of all registered daemons.

=for set_servers Registers all handled daemons in an array.

=for run Dispatches the commandline command (start, stop, restart, status) to
all its daemons.

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut

