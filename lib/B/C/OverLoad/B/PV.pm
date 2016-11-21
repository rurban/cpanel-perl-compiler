package B::PV;

use strict;

use B qw/cstring SVf_IsCOW SVf_ROK SVf_POK SVp_POK SVs_GMG SVs_SMG SVf_READONLY SVs_OBJECT/;
use B::C::Config;
use B::C::Save qw/savepvn savecowpv/;
use B::C::Save::Hek qw/save_shared_he/;
use B::C::File qw/xpvsect svsect free assign_hekkey2pv/;
use B::C::Helpers qw/is_shared_hek read_utf8_string get_index/;

sub SVpbm_VALID { 0x40000000 }
sub SVp_SCREAM  { 0x00008000 }    # method name is DOES

sub do_save {
    my ( $sv, $fullname, $custom ) = @_;

    my $shared_hek = is_shared_hek($sv);

    my ( $savesym, $cur, $len, $pv, $static, $flags ) = save_pv_or_rv( $sv, $fullname );

    # sv_free2 problem with !SvIMMORTAL and del_SV
    my $refcnt = $sv->REFCNT;
    if ( $fullname && $fullname eq 'svop const' ) {
        $refcnt = DEBUGGING() ? 1000 : 0x7fffffff;
    }

    if ( ref $custom ) {    # used when downgrading a PVIV / PVNV to IV
        $flags  = $custom->{flags}  if defined $custom->{flags};
        $refcnt = $custom->{refcnt} if defined $custom->{refcnt};
    }

    # static pv, do not destruct. test 13 with pv0 "3".
    if ( $B::C::const_strings and !$shared_hek and $flags & SVf_READONLY and !$len ) {
        $flags &= ~0x01000000;
        debug( pv => "constpv turn off SVf_FAKE %s %s\n", cstring($pv), $fullname );
    }

    xpvsect()->comment("stash, magic, cur, len");
    xpvsect()->sadd( "Nullhv, {0}, %u, {%u}", $cur, $len );

    svsect()->comment("any, refcnt, flags, sv_u");
    $savesym = $savesym eq 'NULL' ? '0' : ".svu_pv=(char*) $savesym";
    my $sv_ix = svsect()->sadd( '&xpv_list[%d], %Lu, 0x%x, {%s}', xpvsect()->index, $refcnt, $flags, $savesym );

    if ( $shared_hek and !$static ) {
        my $hek = save_shared_he( $pv, $fullname );
        if ( $hek ne 'NULL' ) {
            assign_hekkey2pv()->add( $sv_ix, get_index($hek) );
        }
    }

    my $s = "sv_list[$sv_ix]";
    svsect()->debug( $fullname, $sv );

    return "&" . $s;
}

sub save_pv_or_rv {
    my ( $sv, $fullname ) = @_;

    my $rok = $sv->FLAGS & SVf_ROK;
    my $pok = $sv->FLAGS & ( SVf_POK | SVp_POK );
    my $gmg = $sv->FLAGS & SVs_GMG;

    my $flags = $sv->FLAGS;

    my ( $static, $shared_hek ) = ( 1, is_shared_hek($sv) );

    $static = 0 if ( ( $sv->FLAGS & ( SVp_SCREAM | SVpbm_VALID ) ) == ( SVp_SCREAM | SVpbm_VALID ) );    # ??
    $static = 0 if !( $flags & SVf_ROK ) and $sv->PV and $sv->PV =~ /::bootstrap$/;

    if ( $shared_hek && !$static ) {
        my $savesym = 'NULL';
        my ( $is_utf8, $cur ) = read_utf8_string( $sv->PV );
        my $len = 0;                                                                                     # hek should have len 0

        my $pv = $sv->PV;                                                                                # we know that a shared_hek as POK

        return ( $savesym, $cur, $len, $pv, $static, $flags );
    }

    my $pv = "";
    my ( $savesym, $cur, $len ) = savecowpv($pv);

    # overloaded VERSION symbols fail to xs boot: ExtUtils::CBuilder with Fcntl::VERSION (i91)
    # 5.6: Can't locate object method "RV" via package "B::PV" Carp::Clan
    if ($rok) {

        # this returns us a SV*. 5.8 expects a char* in xpvmg.xpv_pv
        debug( sv => "save_pv_or_rv: B::RV::save_op(" . ( $sv || '' ) );

        my $newsym = B::RV::save_op( $sv, $fullname );

        # newsym can be a get_cv call from get_cv_string
        if ( $newsym =~ qr{(?:get_cv|get_cvn_flags)\(} ) {    # Moose::Util::TypeConstraints::Builtins::_RegexpRef xtest #350
            $static = 0;
            $pv     = $newsym;
        }
        else {
            $savesym = $newsym;
        }
        $static = 1;                                          # ??
    }
    else {
        $flags |= SVf_IsCOW;                                  # only flags as COW if it's not a reference

        if ($pok) {
            $pv = pack "a*", $sv->PV;                         # XXX!
            $cur = ( $sv and $sv->can('CUR') and ref($sv) ne 'B::GV' ) ? $sv->CUR : length($pv);
        }
        else {
            if ( $gmg && $fullname ) {
                no strict 'refs';
                $pv = ( $fullname and ref($fullname) ) ? "${$fullname}" : '';
                $cur = length( pack "a*", $pv );
                $pok = 1;
            }
        }

        ( $savesym, $cur, $len ) = savecowpv($pv) if $pok;
    }

    $fullname = '' if !defined $fullname;

    debug(
        pv => "Saving pv %s %s cur=%d, len=%d, static=%d cow=%d %s",
        $savesym, cstring($pv), $cur, $len,
        $static, $static, $shared_hek ? "shared, $fullname" : $fullname
    );

    return ( $savesym, $cur, $len, $pv, $static, $flags );
}

1;
