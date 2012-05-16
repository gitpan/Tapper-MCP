package MFoo;
        use Moose;

        use MUser;
        use Data::Dumper;

        sub hello {
                my ($self, $u) = @_;
		#print STDERR Dumper($u);
                print "# HELLO ", $u->hotstuff, "\n";
        }

1;
