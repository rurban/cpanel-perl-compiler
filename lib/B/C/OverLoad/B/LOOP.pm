package B::LOOP;

use strict;

use B::C::Config;
use B::C::File qw/loopsect init/;
use B::C::Helpers qw/do_labels/;
use B::C::Helpers::Symtable qw/savesym/;

sub do_save {
    my ( $op, $level ) = @_;

    $level ||= 0;

    #debug( op =? "LOOP: redoop %s, nextop %s, lastop %s\n",
    #		 peekop($op->redoop), peekop($op->nextop),
    #		 peekop($op->lastop));
    loopsect()->comment_common("first, last, redoop, nextop, lastop");
    my $ix = loopsect()->sadd(
        "%s, s\\_%x, s\\_%x, s\\_%x, s\\_%x, s\\_%x",
        $op->_save_common,
        ${ $op->first },
        ${ $op->last },
        ${ $op->redoop },
        ${ $op->nextop },
        ${ $op->lastop }
    );
    loopsect()->debug( $op->name, $op );

    my $sym = savesym( $op, "(OP*)&loop_list[$ix]" );    # save it earlier for do_labels ?
    do_labels( $op, $level + 1, qw(first last redoop nextop lastop) );

    return $sym;
}

1;
