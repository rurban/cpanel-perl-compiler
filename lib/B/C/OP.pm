package B::C::OP;

use strict;
use B::C::Helpers::Symtable qw/savesym objsym/;

my $last;
my $count;
my $_stack;

sub save_constructor {

    # we cannot trust the OP passed to know which call we should call
    #   we are hardcoding it using a constructor for save
    my $for = shift or die;

    return sub {
        my ( $op, @args ) = @_;

        if (1) {    # infinite loop detection ( for debugging purpose)

            if ( $last && $last eq $op ) {
                ++$count;
                if ( $count == 10 ) {    # let's save a shorter stack to be able to detect it later
                    $_stack = sprintf(
                        "##### detect a potential infinite loop:\n%s - %s [ v=%s ] from %s\n",
                        ref $op,
                        $op,
                        ref $op eq 'B::IV' ? int( $op->IVX ) : "",
                        'B::C::Save'->can('stack_flat')->()
                    );

                    #die;
                }
                if ( $count == 10_000 ) {    # make this counter high enough to pass most of the common cases
                    print STDERR $_stack;
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
        my $sym;
        eval { $sym = $for->can('do_save')->( $op, @args ); 1 }
          or die "$@\n:" . 'B::C::Save'->can('stack_flat')->();
        savesym( $op, $sym ) if defined $sym;
        return $sym;
    };

}

1;
