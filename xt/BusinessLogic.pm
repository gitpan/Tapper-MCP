package BusinessLogic;
        use 5.010;
        use Moose;
        use TypeLib;
        sub hello {
                my ($self, $act) = @_;
                say "HELLO ", $act->name;
        }

1;

