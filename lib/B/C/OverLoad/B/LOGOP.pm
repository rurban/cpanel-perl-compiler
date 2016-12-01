package B::LOGOP;

use strict;

use B::C::File qw/logopsect init/;
use B::C::Helpers qw/do_labels/;
use B::C::Helpers::Symtable qw/savesym/;

sub do_save {
    my ( $op, $level ) = @_;

    $level ||= 0;

    logopsect()->comment_common("first, other");
    logopsect()->sadd( "%s, s\\_%x, s\\_%x", $op->_save_common, ${ $op->first }, ${ $op->other } );
    logopsect()->debug( $op->name, $op );
    my $ix = logopsect()->index;
    my $sym = savesym( $op, "(OP*)&logop_list[$ix]" );    # save it earlier ?
    do_labels( $op, $level + 1, 'first', 'other' );
    return $sym;
}

1;
