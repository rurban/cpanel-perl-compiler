package B::UNOP;

use strict;

use B::C::Config;
use B::C::File qw/unopsect init/;
use B::C::Helpers qw/do_labels padop_name svop_name curcv/;

sub do_save {
    my ( $op, $level ) = @_;

    $level ||= 0;

    unopsect()->comment_common("first");
    my $ix = unopsect()->sadd( "%s, s\\_%x", $op->_save_common, ${ $op->first } );
    unopsect()->debug( $op->name, $op );

    if ( $op->name eq 'method' and $op->first and $op->first->name eq 'const' ) {
        my $method = svop_name( $op->first );
    }
    do_labels( $op, $level + 1, 'first' );

    return "(OP*)&unop_list[$ix]";
}

1;
