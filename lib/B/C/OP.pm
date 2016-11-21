package B::C::OP;

use strict;
use B::C::Helpers::Symtable qw/savesym objsym/;

my $last;
my $count;

sub save {
    my ( $op, @args ) = @_;

    if (1) {    # infinite loop detection ( for debugging purpose)

        if ( $last && $last eq $op ) {
            ++$count;
            if ( $count == 10_000 ) {    # make this counter high enough to pass most of the common cases
                print STDERR sprintf( "#####\n%s - %s from %s\n", ref $op, $op, 'B::C::Save'->can('stack_flat')->() );
                die;
            }
        }
        else {
            $last  = "$op";
            $count = 1;
        }
    }

    # cache lookup
    {
        my $sym = objsym($op);
        return $sym if defined $sym;
    }

    # call the real save function and cache the return value{
    my $sym = $op->do_save(@args);
    savesym( $op, $sym ) if $sym;
    return $sym;
}

1;
