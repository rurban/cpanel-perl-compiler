package B::PVIV;

use strict;
use B::C::Config;
use B::C::Save qw/savepvn/;
use B::C::File qw/xpvivsect svsect init/;
use B::C::Decimal qw/get_integer_value/;
use B::C::Optimizer::DowngradePVXV qw/downgrade_pviv/;

sub do_save {
    my ( $sv, $fullname ) = @_;

    my $downgraded = downgrade_pviv( $sv, $fullname );
    return $downgraded if defined $downgraded;

    # save the PVIV
    my ( $savesym, $cur, $len, $pv, $static, $flags ) = B::PV::save_pv_or_rv( $sv, $fullname );

    xpvivsect()->comment('STASH, MAGIC, cur, len, IVX');
    xpvivsect()->sadd(
        "Nullhv, {0}, %u, {%u}, {%s}",
        $cur, $len, get_integer_value( $sv->IVX )
    );    # IVTYPE long

    # save the pv
    my $ix = svsect()->sadd(
        "&xpviv_list[%d], %u, 0x%x, {.svu_pv=(char*) %s}",
        xpvivsect()->index, $sv->REFCNT, $flags, $savesym
    );
    svsect()->debug( $fullname, $sv );
    return "&sv_list[" . $ix . "]";
}

1;
