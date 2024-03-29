package Tapper::MCP;
# git description: v4.1.1-16-g84f6d4c

BEGIN {
  $Tapper::MCP::AUTHORITY = 'cpan:TAPPER';
}
{
  $Tapper::MCP::VERSION = '4.1.2';
}
# ABSTRACT: Tapper - Central master control program of Tapper automation

use warnings;
use strict;

use Tapper::Config;
use Moose;

extends 'Tapper::Base';

sub cfg
{
        my ($self) = @_;
        return Tapper::Config->subconfig();
}

1;

__END__
=pod

=encoding utf-8

=head1 NAME

Tapper::MCP - Tapper - Central master control program of Tapper automation

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut

