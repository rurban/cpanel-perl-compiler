package B::PVOP;

use strict;

use B qw/cstring/;

use B::C::File qw/loopsect pvopsect init/;
use B::C::Helpers qw/strlen_flags/;

sub do_save {
    my ( $op, $level ) = @_;

    # op_pv must be dynamic
    loopsect()->comment_common("pv");

    my $ix = pvopsect()->sadd( "%s, NULL", $op->_save_common );
    pvopsect()->debug( $op->name, $op );

    my ( $cstring, $cur, $utf8 ) = strlen_flags( $op->pv );    # utf8 in op_private as OPpPV_IS_UTF8 (0x80)

    init()->sadd( "pvop_list[%d].op_pv = savesharedpvn(%s, %u);", $ix, $cstring, $cur );

    return "(OP*)&pvop_list[$ix]";
}

1;
