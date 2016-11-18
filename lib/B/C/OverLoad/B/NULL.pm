package B::NULL;

use strict;
use B::C::Config;
use B::C::File qw/svsect init/;

sub do_save {
    my ( $sv, $fullname ) = @_;

    # debug
    if ( $$sv == 0 ) {
        verbose("NULL::save for sv = 0 called from @{[(caller(1))[3]]}");
        return "(void*)Nullsv";
    }

    my $ix = svsect()->sadd( "NULL, %Lu, 0x%x, {0}", $sv->REFCNT, $sv->FLAGS );
    debug( sv => "Saving SVt_NULL sv_list[$ix]" );

    #svsect()->debug( $fullname, $sv ); # XXX where is this possible?
    if ( debug('flags') and DEBUG_LEAKING_SCALARS() ) {    # add index to sv_debug_file to easily find the Nullsv
                                                           # svsect()->debug( "ix added to sv_debug_file" );
        init()->sadd( 'sv_list[%d].sv_debug_file = savesharedpv("NULL sv_list[%d] 0x%x");', svsect()->index, svsect()->index, $sv->FLAGS );
    }

    return sprintf( "&sv_list[%d]", $ix );
}

1;
