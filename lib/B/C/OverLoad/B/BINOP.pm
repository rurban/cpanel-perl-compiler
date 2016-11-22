package B::BINOP;

use strict;

use B qw/opnumber/;
use B::C::Config;
use B::C::File qw/binopsect init/;
use B::C::Helpers qw/do_labels/;

my $OP_CUSTOM = opnumber('custom');

sub do_save {
    my ( $op, $level ) = @_;

    $level ||= 0;

    binopsect->comment_common("first, last");
    binopsect->sadd( "%s, s\\_%x, s\\_%x", $op->_save_common, ${ $op->first }, ${ $op->last } );
    binopsect->debug( $op->name, $op->flagspv );
    my $ix = binopsect->index;

    my $ppaddr = $op->ppaddr;
    if ( $op->type == $OP_CUSTOM ) {
        my $ptr = $$op;
        if ( $op->name eq 'Devel_Peek_Dump' or $op->name eq 'Dump' ) {
            verbose('custom op Devel_Peek_Dump');
            $B::C::devel_peek_needed++;
            $ppaddr = 'S_pp_dump';
            init()->sadd( "binop_list[%d].op_ppaddr = %s;", $ix, $ppaddr );
        }
        else {
            vebose( "Warning: Unknown custom op " . $op->name );
            $ppaddr = sprintf( 'Perl_custom_op_xop(aTHX_ INT2PTR(OP*, 0x%x))', $$op );
            init()->sadd( "binop_list[%d].op_ppaddr = %s;", $ix, $ppaddr );
        }
    }

    do_labels( $op, $level + 1, 'first', 'last' );

    return "(OP*)&binop_list[$ix]";
}

1;
