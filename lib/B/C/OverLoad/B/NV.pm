package B::NV;

use strict;

use B q/SVf_IOK/;

use B::C::Config;
use B::C::File qw/xpvnvsect svsect/;
use B::C::Decimal qw/get_double_value/;
use B::C::Helpers::Symtable qw/objsym savesym/;

# TODO NVs should/could be bodyless ? view IVs, UVs
sub save {
    my ( $sv, $fullname, $custom ) = @_;

    my $sym = objsym($sv);
    return $sym if defined $sym;

    my $svflags = $sv->FLAGS;
    my $refcnt  = $sv->REFCNT;

    if ( ref $custom ) {    # used when downgrading a PVIV / PVNV to IV
        $svflags = $custom->{flags}  if defined $custom->{flags};
        $refcnt  = $custom->{refcnt} if defined $custom->{refcnt};
    }

    my $nv = get_double_value( $sv->NV );
    $nv .= '.00' if $nv =~ /^-?\d+$/;

    # IVX is invalid in B.xs and unused
    my $iv = $svflags & SVf_IOK ? $sv->IVX : 0;

    xpvnvsect()->comment('STASH, MAGIC, cur, len, IVX, NVX');
    my $xpvn_ix = xpvnvsect()->add( sprintf( 'Nullhv, {0}, 0, {0}, {%ld}, {%s}', $iv, $nv ) );

    my $sv_ix = svsect()->add( sprintf( '&xpvnv_list[%d], %Lu, 0x%x , {0}', $xpvn_ix, $refcnt, $svflags ) );

    svsect()->debug( $fullname, $sv );
    debug(
        sv => "Saving NV %s to xpvnv_list[%d], sv_list[%d]\n",
        $nv, xpvnvsect()->index, $sv_ix
    );
    return savesym( $sv, sprintf( "&sv_list[%d]", $sv_ix ) );
}

1;
