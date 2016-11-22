package B::REGEXP;

use strict;

use B qw/cstring RXf_EVAL_SEEN/;
use B::C::Config;
use B::C::File qw/init svsect xpvsect/;

# post 5.11: When called from B::RV::save_op not from PMOP::save precomp
sub do_save {
    my ( $sv, $fullname ) = @_;

    my $pv  = $sv->PV;
    my $cur = $sv->CUR;

    # construct original PV
    $pv =~ s/^(\(\?\^[adluimsx-]*\:)(.*)\)$/$2/;
    $cur -= length( $sv->PV ) - length($pv);
    my $cstr = cstring($pv);

    # Unfortunately this XPV is needed temp. Later replaced by struct regexp.
    my $xpv_ix = xpvsect()->sadd( "Nullhv, {0}, %u, {%u}", $cur, 0 );
    my $ix = svsect()->sadd(
        "&xpv_list[%d], %Lu, 0x%x, {NULL}",
        $xpv_ix, $sv->REFCNT, $sv->FLAGS
    );
    debug( rx => "Saving RX $cstr to sv_list[$ix]" );

    if ( $sv->EXTFLAGS & RXf_EVAL_SEEN ) {
        init()->add("PL_hints |= HINT_RE_EVAL;");
    }

    # replace sv_any->XPV with struct regexp. need pv and extflags
    init()->sadd( 'SvANY(&sv_list[%d]) = SvANY(CALLREGCOMP(newSVpvn(%s, %d), 0x%x));', $ix, $cstr, $cur, $sv->EXTFLAGS );
    if ( $sv->EXTFLAGS & RXf_EVAL_SEEN ) {
        init()->add("PL_hints &= ~HINT_RE_EVAL;");
    }

    init()->add("sv_list[$ix].sv_u.svu_rx = (struct regexp*)sv_list[$ix].sv_any;");

    svsect()->debug( $fullname, $sv );
    $sv->save_magic($fullname);

    return sprintf( "&sv_list[%d]", $ix );
}

1;
