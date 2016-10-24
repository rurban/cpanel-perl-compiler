package B::PVIV;

use strict;
use B::C::Config;
use B::C::Save qw/savepvn/;
use B::C::File qw/xpvivsect svsect init/;
use B::C::Decimal qw/get_integer_value/;
use B::C::Helpers::Symtable qw/objsym savesym/;
use B::C::Optimizer::DowngradePVXV qw/downgrade_pviv/;

sub save {
    my ( $sv, $fullname ) = @_;
    my $sym = objsym($sv);

    if ( defined $sym ) {
        if ($B::C::in_endav) {
            debug( av => "in_endav: static_free without $sym" );
            @B::C::static_free = grep { !/$sym/ } @B::C::static_free;
        }
        return $sym;
    }

    my $downgraded = downgrade_pviv( $sv, $fullname );
    if ( defined $downgraded ) {
        savesym( $sv, $downgraded );
        return $downgraded;
    }

    # save the PVIV

    my ( $savesym, $cur, $len, $pv, $static, $flags ) = B::PV::save_pv_or_rv( $sv, $fullname );

    xpvivsect()->comment('STASH, MAGIC, cur, len, IVX');
    xpvivsect()->add(
        sprintf(
            "Nullhv, {0}, %u, {%u}, {%s}",
            $cur, $len, get_integer_value( $sv->IVX )
        )
    );    # IVTYPE long

    # save the pv
    svsect()->add(
        sprintf(
            "&xpviv_list[%d], %u, 0x%x, {.svu_pv=(char*) %s}",
            xpvivsect()->index, $sv->REFCNT, $flags, $savesym
        )
    );
    svsect()->debug( $fullname, $sv );
    my $s = "sv_list[" . svsect()->index . "]";
    return savesym( $sv, "&" . $s );
}

1;
