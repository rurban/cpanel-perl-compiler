package B::C::OP;

use strict;
use B::C::Helpers::Symtable qw/savesym objsym/;

sub save {
    my ( $op, @args ) = @_;

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
