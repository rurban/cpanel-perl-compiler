package B::UV;

use strict;

use B::C::Flags ();

use B::C::Config;
use B::C::File qw/svsect init/;
use B::C::Decimal qw/u32fmt/;

sub do_save {
    my ( $sv, $fullname ) = @_;

    my $uvuformat = $B::C::Flags::Config{uvuformat};
    $uvuformat =~ s/"//g;    #" poor editor

    my $uvx  = $sv->UVX;
    my $suff = 'U';
    $suff .= 'L' if $uvx > 2147483647;

    my $u32fmt = u32fmt();
    my $ix     = svsect()->sadd(
        "NULL, $u32fmt, 0x%x, {.svu_uv=${uvx}${suff}}",
        $sv->REFCNT, $sv->FLAGS
    );

    my $sym = sprintf( "&sv_list[%d]", $ix );

=pod
    Since 5.24 we can access the IV/NV/UV value from either the union from the main SV body
    or also from the SvANY of it...

    view IV.pm for more informations

=cut

    # the bc_SET_SVANY_FOR_BODYLESS_UV version just uses extra parens to be able to use a pointer [need to add patch to perl]
    init()->sadd( "bc_SET_SVANY_FOR_BODYLESS_UV(%s);", $sym );

    svsect()->debug( $fullname, $sv );

    return $sym;
}

1;
