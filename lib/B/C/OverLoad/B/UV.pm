package B::UV;

use strict;

use B::C::Flags ();

use B::C::Config;
use B::C::File qw/svsect init/;
use B::C::Helpers::Symtable qw/objsym savesym/;
use B::C::Decimal qw/u32fmt/;

sub save {
    my ( $sv, $fullname ) = @_;

    my $sym = objsym($sv);
    return $sym if defined $sym;

    my $uvuformat = $B::C::Flags::Config{uvuformat};
    $uvuformat =~ s/"//g;    #" poor editor

    my $uvx  = $sv->UVX;
    my $suff = 'U';
    $suff .= 'L' if $uvx > 2147483647;

    my $u32fmt = u32fmt();
    my $i      = svsect()->add(
        sprintf(
            "NULL, $u32fmt, 0x%x, {.svu_uv=${uvx}${suff}}",
            $sv->REFCNT, $sv->FLAGS
        )
    );

    $sym = savesym( $sv, sprintf( "&sv_list[%d]", $i ) );

=pod
    Since 5.24 we can access the IV/NV/UV value from either the union from the main SV body
    or also from the SvANY of it...

    As IV family do not need/have one SvANY we are going to cheat....
    by setting a 'virtual' pointer to the SvANY to an unsignificant memory address
    but once we try to access to the IV value of it... this will point to the
    single location where it's store in the body of the main SV....

    So two differents way to access to the same memory location.

=cut

    #32bit  - sizeof(void*), 64bit: - 2*ptrsize
    if ( $B::C::Flags::Config{ptrsize} == 4 ) {
        init()->add( sprintf( "SvANY(%s) = (void*)%s - sizeof(void*);", $sym, $sym ) );
    }
    else {
        init()->add( sprintf( "SvANY(%s) = (char*)%s - %d;", $sym, $sym, 2 * $B::C::Flags::Config{ptrsize} ) );
    }

    # TODO: we would like to use something like this, this is breaking op/64bitint.t
    #init()->add( sprintf( "sv_list[%d].sv_any = (void*)&sv_list[%d] - STRUCT_OFFSET(XPVUV, xuv_uv);", $i, $i ) );

    svsect()->debug( $fullname, $sv );

    return $sym;
}

1;
__END__
 from sv.h

 /*
 * Bodyless IVs and NVs!
 *
 * Since 5.9.2, we can avoid allocating a body for SVt_IV-type SVs.
 * Since the larger IV-holding variants of SVs store their integer
 * values in their respective bodies, the family of SvIV() accessor
 * macros would  naively have to branch on the SV type to find the
 * integer value either in the HEAD or BODY. In order to avoid this
 * expensive branch, a clever soul has deployed a great hack:
 * We set up the SvANY pointer such that instead of pointing to a
 * real body, it points into the memory before the location of the
 * head. We compute this pointer such that the location of
 * the integer member of the hypothetical body struct happens to
 * be the same as the location of the integer member of the bodyless
 * SV head. This now means that the SvIV() family of accessors can
 * always read from the (hypothetical or real) body via SvANY.
 *
 * Since the 5.21 dev series, we employ the same trick for NVs
 * if the architecture can support it (NVSIZE <= IVSIZE).
 */

/* The following two macros compute the necessary offsets for the above
 * trick and store them in SvANY for SvIV() (and friends) to use. */

#ifdef PERL_CORE
#  define SET_SVANY_FOR_BODYLESS_IV(sv) \
       SvANY(sv) =   (XPVIV*)((char*)&(sv->sv_u.svu_iv) \
                    - STRUCT_OFFSET(XPVIV, xiv_iv))

#  define SET_SVANY_FOR_BODYLESS_NV(sv) \
       SvANY(sv) =   (XPVNV*)((char*)&(sv->sv_u.svu_nv) \
                    - STRUCT_OFFSET(XPVNV, xnv_u.xnv_nv))
#endif
