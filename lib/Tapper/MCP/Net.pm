package Tapper::MCP::Net;
BEGIN {
  $Tapper::MCP::Net::AUTHORITY = 'cpan:TAPPER';
}
{
  $Tapper::MCP::Net::VERSION = '4.1.2';
}

use strict;
use warnings;
use English '-no_match_vars';

use 5.010;

use Moose;
use Socket;
use Net::SSH;
use Net::SCP;
use IO::Socket::INET;
use Sys::Hostname;
use File::Basename;
use YAML;

extends 'Tapper::MCP';

use Tapper::Model qw(model get_hardware_overview);


sub conserver_connect
{
        my ($self, $system, $conserver, $conserver_port, $conuser) = @_;
        $conserver      ||= $self->cfg->{conserver}{server};
        $conserver_port ||= $self->cfg->{conserver}{port};
        $conuser        ||= $self->cfg->{conserver}{user};

        my $sock = IO::Socket::INET->new(PeerPort => $conserver_port,
                                         PeerAddr => $conserver,
                                         Proto    => 'tcp');

        return ("Can't open connection:$!") unless $sock;
        my $data=<$sock>; return($data) unless $data=~/^ok/;

        print $sock "login $conuser\n";
        $data=<$sock>; return($data) unless $data=~/^ok/;

        print $sock "call $system\n";
        my $port=<$sock>;
        if ($port=~ /@(\w+)/) {
                close $sock;
                return $self->conserver_connect ($system,$1,$conserver_port,$conuser);
        } else {
                if ($port !~ /^\d+/) {
                        close $sock;
                        return $port; # answer in $port is an error message
                }
        }


        print $sock "exit\n";
        $data=<$sock>; return($data) unless $data=~/^goodbye/;
        close $sock;

        $sock = IO::Socket::INET->new(PeerPort => int($port),
                                      PeerAddr => $conserver,
                                      Proto    => 'tcp');
        return ("Can't open connection to $conserver:$!") unless $sock;


        $data=<$sock>;return($data) unless $data=~/^ok/;
        print $sock "login $conuser\n";
        $data=<$sock>;return($data) unless $data=~/^ok/;
        print $sock "call $system\n";
        $data=<$sock>;return($data) unless $data=~/^(\[attached\]|\[spy\])/;

        print ($sock "\005c;\n");  # console needs to be "activated"
        $data=<$sock>;return($data) unless $data=~/^(\[connected\])/;
        return($sock);
}


sub conserver_disconnect
{
        my ($self, $sock) = @_;
        if ($sock) {
                eval {
                        local $SIG{ALRM} = sub { die 'Timeout'; };
                        alarm (2);
                        if ($sock->can("connected") and $sock->connected()) {
                                print ($sock "\005c.\n");
                                <$sock>; # ignore return value, since we close the socket anyway
                        }
                };
                alarm (2);
                $sock->close() if $sock->can("close");
        }
}



sub start_simnow
{
        my ($self, $hostname) = @_;

        my $simnow_installer = $self->cfg->{files}{simnow_installer};
        my $server = Sys::Hostname::hostname() || $self->cfg->{mcp_host};
        my $retval = Net::SSH::ssh("root\@$hostname",$simnow_installer, "--host=$server");
        return "Can not start simnow installer: $!" if $retval;


        $self->log->info("Simnow installation started on $hostname.");
        return 0;

}



sub start_ssh
{
        my ($self, $hostname) = @_;

        my $tapper_script = $self->cfg->{files}{tapper_prc};
        my $tftp_host = $self->cfg->{mcp_host};
        my $error = Net::SSH::ssh("$hostname","TAPPER_TEST_TYPE=ssh $tapper_script --host $tftp_host");
        return "Can not start PRC with ssh: $error" if $error;
        return 0;
}


sub start_local
{
        my ($self, $path_to_config) = @_;

        my $error = qx(tapper-client --config $path_to_config);
        return "Can not start PRC locally: $error" if $error;
        return 0;
}




sub install_client_package
{
        my ($self, $hostname, $package) = @_;

        my $dest_path  = $package->{dest_path} || '/tmp';
        $dest_path .= "/tapper-clientpkg.tgz";

        my $arch = $package->{arch};
        return "No architecture defined. Can not install client package" if not $arch;
        my $clientpkg = $self->cfg->{files}{tapper_package}{$arch};

        $clientpkg = $self->cfg->{paths}{package_dir}.$clientpkg
          if not $clientpkg =~ m,^/,;

        my $scp     = Net::SCP->new($hostname);
        my $success = $scp->put(
                               $clientpkg,
                               $dest_path,
                              );
        return "Can not copy client package '$clientpkg' to $hostname:/$dest_path: ".$scp->{errstr} if not $success;

        my $error = Net::SSH::ssh("$hostname","tar -xzf $dest_path -C /");
        return "Can not unpack client package on $hostname: $!" if $error;
        return 0;
}




sub reboot_system
{
        my ($self, $host, $hard) = @_;
        $self->log->debug("Trying to reboot $host.");


        my $reset_plugin         = $self->cfg->{reset_plugin};
        my $reset_plugin_options = $self->cfg->{reset_plugin_options};

        my $reset_class = "Tapper::MCP::Net::Reset::$reset_plugin";
        eval "use $reset_class"; ## no critic

        if ($@) {
                return "Could not load $reset_class";
        } else {
                no strict 'refs'; ## no critic
                $self->log->debug("Call $reset_class->reset_host($host, $reset_plugin_options)");
                my $reset_object = $reset_class->new();
                my ($error, $retval) = $reset_object->reset_host($host, $reset_plugin_options);
                if ($error) {
                        $self->log->error("Error occured: ".$retval);
                        return $retval;
                }
                return 0;
        }
}



sub write_grub_file
{
        my ($self, $system, $text) = @_;
        return "No grub text given" unless $text;

        my $grub_file    = $self->cfg->{paths}{grubpath}."/$system.lst";
        $self->log->debug("writing grub file $grub_file");

        # create the initial grub file for installation of the test system,
        open (my $GRUBFILE, ">", $grub_file) or return "Can open ".$self->cfg->{paths}{grubpath}."/$system.lst for writing: $!";
        print $GRUBFILE $text;
        close $GRUBFILE or return "Can't save grub file for $system:$!";
        return(0);
}



sub hw_report_create
{
        my ($self, $testrun_id) = @_;
        my $testrun = model->resultset('Testrun')->find($testrun_id);
        my $host;
        eval {
                # parts of this chain may be undefined

                $host = $testrun->testrun_scheduling->host;
        };
        return (1, qq(testrun '$testrun_id' has no host associated)) unless $host;

        my $data = get_hardware_overview($host->id);
        my $yaml = Dump($data);
        $yaml   .= "...\n";
        $yaml =~ s/^(.*)$/  $1/mg;  # indent
        my $report = sprintf("
TAP Version 13
1..2
# Tapper-Reportgroup-Testrun: %s
# Tapper-Suite-Name: Hardwaredb Overview
# Tapper-Suite-Version: %s
# Tapper-Machine-Name: %s
ok 1 - Getting hardware information
%s
ok 2 - Sending
", $testrun_id, $Tapper::MCP::VERSION, $host->name, $yaml);

        return (0, $report);
}

1;

__END__
=pod

=encoding utf-8

=head1 NAME

Tapper::MCP::Net

=head2 conserver_connect

This function opens a connection to the conserver. Conserver, port and user
can be given as arguments, yet are optional.
@param string - system to open a console to
@opt   string - Address or name of the console server
@opt   int    - port number of the console server
@opt   string - username to be used

@returnlist success - (IO::Socket::INET object)
@returnlist error   - (error string)

=head2 conserver_disconnect

Disconnect the filehandle given as first argument from the conserver.
We first try to quit kindly but if this fails (by what reason ever)
the filehandle is simply closed. Closing a socket can not fail, so the
function always succeeds. Thus no return value is needed.

@param  IO::Socket::INET - file handle connected to the conserver

@return none

=head2 start_simnow

Start a simnow installation on given host. Installer is supposed to
start the simnow controller in turn.

@param string - hostname

@return success - 0
@return error   - error string

=head2 start_ssh

Start a ssh testrun on given host. This starts both the Installer and PRC.

@param string - hostname

@return success - 0
@return error   - error string

=head2 start_local

Start a testrun locally. This starts both the Installer and PRC.

@param string - path to config

@return success - 0
@return error   - error string

=head2 install_client_package

Install client package of given architecture on given host at optional
given possition.

@param string   - hostname
@param hash ref - contains arch and dest_path

@return success - 0
@return error   - error string

=head2 reboot_system

Reboot the named system. First we try to do it softly, if that does not
work, we try a hard reboot. Unfortunately this does not give any
feedback. Thus you have to wait for the typical reboot time of the
system in question and if the system does not react after this time
assume that the reboot failed. This is not included in this function,
since it would make it to complex.

@param string - name of the system to be rebooted
@param bool   - hard reset without ssh

@return success - 0
@return error   - error string

=head2 write_grub_file

Write the given text to the grub file for the system given as parameter.

@param string - name of the system
@param string - text to put into grub file

@return success - 0
@return error   - error string

=head2 hw_report_create

Create a report containing the test machines hw config as set in the hardware
db. Leave the sending to caller

@param int - testrun id

@return success - (0, hw_report)
@return error   - (1, error string)

=head1 AUTHOR

AMD OSRC Tapper Team <tapper@amd64.org>

=head1 COPYRIGHT AND LICENSE

This software is Copyright (c) 2012 by Advanced Micro Devices, Inc..

This is free software, licensed under:

  The (two-clause) FreeBSD License

=cut

