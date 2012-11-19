package Tapper::MCP::Net::Reset::DoNothing;
BEGIN {
  $Tapper::MCP::Net::Reset::DoNothing::AUTHORITY = 'cpan:TAPPER';
}
{
  $Tapper::MCP::Net::Reset::DoNothing::VERSION = '4.1.1';
}

use strict;
use warnings;

use Moose;
extends 'Tapper::Base';


sub reset_host
{
        my ($self, $host, $options) = @_;

        $self->log->info("Just a fake-reboot, not real.");
        my ($error, $retval) = (1, "$host"."-".$options->{some_dummy_return_message});
        return ($error, $retval);
}

1;

__END__
=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Net::Reset::DoNothing

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut

