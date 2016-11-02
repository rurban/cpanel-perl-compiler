package B::GV;

use strict;

use B qw/cstring svref_2object SVt_PVGV SVf_ROK SVf_UTF8/;

use B::C::Config;
use B::C::Save::Hek qw/save_shared_he/;
use B::C::Packages qw/is_package_used/;
use B::C::File qw/init init2/;
use B::C::Helpers qw/mark_package get_cv_string strlen_flags/;
use B::C::Helpers::Symtable qw/objsym savesym/;
use B::C::Optimizer::ForceHeavy qw/force_heavy/;
use B::C::Packages qw/mark_package_used/;

my %gptable;

sub inc_index {
    return $B::C::gv_index++;
}

sub Save_HV()   { 1 }
sub Save_AV()   { 2 }
sub Save_SV()   { 4 }
sub Save_CV()   { 8 }
sub Save_FORM() { 16 }
sub Save_IO()   { 32 }
sub Save_FILE() { 64 }

my $CORE_SYMS = {
    'main::ENV'    => 'PL_envgv',
    'main::ARGV'   => 'PL_argvgv',
    'main::INC'    => 'PL_incgv',
    'main::STDIN'  => 'PL_stdingv',
    'main::STDERR' => 'PL_stderrgv',
    "main::\010"   => 'PL_hintgv',     # ^H
    "main::_"      => 'PL_defgv',
    "main::@"      => 'PL_errgv',
    "main::\022"   => 'PL_replgv',     # ^R
};

my $CORE_SVS = {                       # special SV syms to assign to the right GvSV

    "main::\\" => 'PL_ors_sv',
    "main::/"  => 'PL_rs',
    "main::@"  => 'PL_errors',
};

sub get_package {
    my $gv = shift;

    return '__ANON__' if ref( $gv->STASH ) eq 'B::SPECIAL';
    return $gv->STASH->NAME;
}

sub is_coresym {
    my $gv = shift;

    return $CORE_SYMS->{ $gv->get_fullname() } ? 1 : 0;
}

sub get_fullname {
    my $gv = shift;

    return $gv->get_package() . "::" . $gv->NAME();
}

sub set_dynamic_gv {
    my $gv = shift;
    return savesym( $gv, sprintf( "dynamic_gv_list[%s]", inc_index() ) );
}

sub save {
    my ( $gv, $filter ) = @_;

    {    # cache lookup
        my $cached_sym = objsym($gv);
        return $cached_sym if defined $cached_sym;
    }

    # return earlier for special cases
    return B::BM::save($gv)       if $gv->FLAGS & 0x40000000;                # SVpbm_VALID # GV $sym isa FBM
    return q/(SV*)&PL_sv_undef/   if B::C::skip_pkg( $gv->get_package() );
    return $gv->save_special_gv() if $gv->is_special_gv();

    my $sym = set_dynamic_gv($gv);

    my $package = $gv->get_package();
    my $gvname  = $gv->NAME();

    # If we come across a stash hash, we therefore have code using it so we need to mark it was used so it won't be deleted.
    if ( $gvname =~ m/::$/ ) {
        my $pkg = $gvname;
        $pkg =~ s/::$//;
        mark_package_used($pkg);
    }

    my $fullname = $gv->get_fullname();

    my $is_empty = $gv->is_empty;
    if ( !defined $gvname and $is_empty ) {    # 5.8 curpad name
        die("We don't think this ever happens");
        return q/(SV*)&PL_sv_undef/;
    }

    my $name = $package eq 'main' ? $gvname : $fullname;

    if ( my $newgv = force_heavy( $package, $fullname ) ) {
        $gv = $newgv;                          # defer to run-time autoload, or compile it in?
        $sym = savesym( $gv, $sym );           # override new gv ptr to sym
    }

    # Core syms are initialized by perl so we don't need to other than tracking the symbol itself see init_main_stash()
    $sym = savesym( $gv, $CORE_SYMS->{$fullname} ) if $gv->is_coresym();

    my $notqual = $package eq 'main' ? 'GV_NOTQUAL' : '0';
    my $was_emptied = save_gv_with_gp( $gv, $sym, $name, $notqual, $is_empty );
    $is_empty = 1 if ($was_emptied);

    my $gvflags = $gv->GvFLAGS;
    my $svflags = $gv->FLAGS;
    init()->sadd( "SvFLAGS(%s) = 0x%x;%s",  $sym, $svflags, debug('flags') ? " /* " . $gv->flagspv . " */"          : "" );
    init()->sadd( "GvFLAGS(%s) = 0x%x; %s", $sym, $gvflags, debug('flags') ? "/* " . $gv->flagspv(SVt_PVGV) . " */" : "" );

    if ( !$is_empty ) {
        my $line = $gv->LINE;

        # S32 INT_MAX
        $line = $line > 2147483647 ? 4294967294 - $line : $line;
        init()->sadd( 'GvLINE(%s) = %d;', $sym, $line );
    }

    # walksymtable creates an extra reference to the GV (#197)
    if ( $gv->REFCNT > 1 ) {
        init()->sadd( "SvREFCNT(%s) = %u;", $sym, $gv->REFCNT );
    }

    return $sym if $is_empty;

    my $gvrefcnt = $gv->GvREFCNT;
    if ( $gvrefcnt > 1 ) {
        init()->sadd( "GvREFCNT(%s) += %u;", $sym, $gvrefcnt - 1 );
    }

    debug( gv => "check which savefields for \"$gvname\"" );

    # attributes::bootstrap is created in perl_parse.
    # Saving it would overwrite it, because perl_init() is
    # called after perl_parse(). But we need to xsload it.
    if ( $fullname eq 'attributes::bootstrap' ) {
        unless ( defined( &{ $package . '::bootstrap' } ) ) {
            verbose("Forcing bootstrap of $package");
            eval { $package->bootstrap };
        }
        mark_package( 'attributes', 1 );

        $B::C::xsub{attributes} = 'Dynamic-' . $INC{'attributes.pm'};    # XSLoader
        $B::C::use_xsloader = 1;
    }

    my $savefields = get_savefields( $gv, $fullname, $filter );

    # There's nothing to save if savefields were not returned.
    return $sym unless $savefields;

    # Don't save subfields of special GVs (*_, *1, *# and so on)
    debug( gv => "GV::save saving subfields $savefields" );

    $gv->save_gv_sv( $fullname, $sym, $package ) if $savefields & Save_SV;

    $gv->save_gv_av( $fullname, $sym ) if $savefields & Save_AV;

    $gv->save_gv_hv( $fullname, $sym, $gvname ) if $savefields & Save_HV;

    $gv->save_gv_cv( $fullname, $sym ) if $savefields & Save_CV;

    $gv->save_gv_format( $fullname, $sym ) if $savefields & Save_FORM;

    $gv->save_gv_io( $fullname, $sym ) if $savefields & Save_IO;

    $gv->save_gv_file( $fullname, $sym ) if $savefields & Save_FILE;

    # Shouldn't need to do save_magic since gv_fetchpv handles that. Esp. < and IO not
    # $gv->save_magic($fullname) if $PERL510;
    debug( gv => "GV::save *$fullname done" );
    return $sym;
}

sub is_special_gv {
    my $gv = shift;

    my $fullname = $gv->get_fullname();
    return 1 if $fullname =~ /^main::std(in|out|err)$/;    # same as uppercase above
    return 1 if $fullname eq 'main::0';                    # dollar_0 already handled before, so don't overwrite it
    return;
}

sub save_special_gv {
    my $gv = shift;

    my $gvname   = $gv->NAME();
    my $fullname = $gv->get_fullname();

    # package is main
    my $cname   = cstring($gvname);
    my $notqual = 'GV_NOTQUAL';

    my $type = 'SVt_PVGV';
    $type = 'SVt_PV' if $fullname eq 'main::0';

    my $sym = $gv->set_dynamic_gv;    # use a dynamic slot from there + cache
    init()->sadd( '%s = gv_fetchpv(%s, %s, %s);', $sym, $cname, $notqual, $type );
    init()->sadd( "SvREFCNT(%s) = %u;", $sym, $gv->REFCNT );

    return $sym;
}

sub save_egv {
    my ($gv) = @_;

    return if $gv->is_empty;

    my $egv = $gv->EGV;
    if ( ref($egv) ne 'B::SPECIAL' && ref( $egv->STASH ) ne 'B::SPECIAL' && $$gv != $$egv ) {
        return $egv->save;
    }

    return;
}

sub save_gv_file {
    my ( $gv, $fullname, $sym ) = @_;

    # XXX Maybe better leave it NULL or asis, than fighting broken
    my $file = save_shared_he( $gv->FILE );
    return if ( !$file or $file eq 'NULL' );

    init()->sadd( "GvFILE_HEK(%s) = &(%s->shared_he_hek);", $sym, $file );

    return;
}

sub save_gv_with_gp {
    my ( $gv, $sym, $name, $notqual, $is_empty ) = @_;

    my $gvname   = $gv->NAME();
    my $svflags  = $gv->FLAGS;
    my $fullname = $gv->get_fullname();

    # Core syms don't have a GP?
    return if $gv->is_coresym;

    my $gvadd = $notqual ? "$notqual|GV_ADD" : "GV_ADD";

    my $was_emptied;

    if ( !$gv->isGV_with_GP ) {
        init()->sadd( "$sym = " . gv_fetchpv_string( $name, $gvadd, 'SVt_PV' ) . ";" );
        return;
    }

    my $gp     = $gv->GP;           # B limitation
    my $egvsym = $gv->save_egv();
    if ( defined($egvsym) && $egvsym !~ m/Null/ ) {
        debug( gv => "Shared GV alias for *%s 0x%x%s to %s", $fullname, $svflags, debug('flags') ? "(" . $gv->flagspv . ")" : "", $egvsym );

        # Shared glob *foo = *bar
        init()->sadd( "%s = %s;", $sym, gv_fetchpv_string( $name, "$gvadd|GV_ADDMULTI", 'SVt_PVGV' ) );
        init()->sadd( "GvGP_set(%s, GvGP(%s));", $sym, $egvsym );
        $was_emptied = 1;
    }
    elsif ( $gp and exists $gptable{ 0 + $gp } ) {
        debug( gv => "Shared GvGP for *%s 0x%x%s %s GP:0x%x", $fullname, $svflags, debug('flags') ? "(" . $gv->flagspv . ")" : "", $gv->FILE, $gp );
        init()->sadd( "%s = %s;", $sym, gv_fetchpv_string( $name, $notqual, 'SVt_PVGV' ) );
        init()->sadd( "GvGP_set(%s, %s);", $sym, $gptable{ 0 + $gp } );
        $was_emptied = 1;
    }
    elsif ( $gp and !$is_empty and $gvname =~ /::$/ ) {
        debug( gv => "Shared GvGP for stash %%%s 0x%x%s %s GP:0x%x", $fullname, $svflags, debug('flags') ? "(" . $gv->flagspv . ")" : "", $gv->FILE, $gp );
        init()->sadd( "%s = %s;", $sym, gv_fetchpv_string( $name, 'GV_ADD', 'SVt_PVHV' ) );
        $gptable{ 0 + $gp } = "GvGP($sym)" if 0 + $gp;
    }
    elsif ( $gp and !$is_empty ) {
        debug( gv => "New GV for *%s 0x%x%s %s GP:0x%x", $fullname, $svflags, debug('flags') ? "(" . $gv->flagspv . ")" : "", $gv->FILE, $gp );

        # XXX !PERL510 and OPf_COP_TEMP we need to fake PL_curcop for gp_file hackery
        init()->sadd( "%s = %s;", $sym, gv_fetchpv_string( $name, $gvadd, 'SVt_PV' ) );
        $gptable{ 0 + $gp } = "GvGP($sym)";
    }
    else {
        init()->sadd( "%s = %s;", $sym, gv_fetchpv_string( $name, $gvadd, 'SVt_PVGV' ) );
    }

    return $was_emptied;
}

sub save_gv_cv {
    my ( $gv, $fullname, $sym ) = @_;

    my $package = $gv->get_package();
    my $gvcv    = $gv->CV;
    if ( !$$gvcv ) {
        debug( gv => "Empty CV $fullname, AUTOLOAD and try again" );
        no strict 'refs';

        # Fix test 31, catch unreferenced AUTOLOAD. The downside:
        # It stores the whole optree and all its children.
        # Similar with test 39: re::is_regexp
        svref_2object( \*{"$package\::AUTOLOAD"} )->save if $package and exists ${"$package\::"}{AUTOLOAD};
        svref_2object( \*{"$package\::CLONE"} )->save    if $package and exists ${"$package\::"}{CLONE};
        $gvcv = $gv->CV;    # try again

        return;
    }

    return unless ref($gvcv) eq 'B::CV';
    return if ref( $gvcv->GV ) eq 'B::SPECIAL' or ref( $gvcv->GV->EGV ) eq 'B::SPECIAL';

    my $gvname = $gv->NAME();
    my $gp     = $gv->GP;

    # Can't locate object method "EGV" via package "B::SPECIAL" at /usr/local/cpanel/3rdparty/perl/520/lib/perl5/cpanel_lib/i386-linux-64int/B/C/OverLoad/B/GV.pm line 450.
    {
        my $package  = $gvcv->GV->EGV->STASH->NAME;    # is it the same than package earlier ??
        my $oname    = $gvcv->GV->EGV->NAME;
        my $origname = $package . "::" . $oname;
        my $cvsym;
        if ( $gvcv->XSUB and $oname ne '__ANON__' and $fullname ne $origname ) {    #XSUB CONSTSUB alias

            debug( pkg => "Boot $package, XS CONSTSUB alias of $fullname to $origname" );
            mark_package( $package, 1 );
            {
                no strict 'refs';
                svref_2object( \&{"$package\::bootstrap"} )->save
                  if $package and defined &{"$package\::bootstrap"};
            }

            # XXX issue 57: incomplete xs dependency detection
            my %hack_xs_detect = (
                'Scalar::Util'  => 'List::Util',
                'Sub::Exporter' => 'Params::Util',
            );
            if ( my $dep = $hack_xs_detect{$package} ) {
                svref_2object( \&{"$dep\::bootstrap"} )->save;
            }

            # must save as a 'stub' so newXS() has a CV to populate
            debug( gv => "save stub CvGV for $sym GP assignments $origname" );
            init2()->sadd( "if ((sv = (SV*)%s))", get_cv_string( $origname, "GV_ADD" ) );
            init2()->sadd( "    GvCV_set(%s, (CV*)SvREFCNT_inc_simple_NN(sv));", $sym );
        }
        elsif ($gp) {
            if ( $fullname eq 'Internals::V' ) {
                $gvcv = svref_2object( \&__ANON__::_V );
            }

            # TODO: may need fix CvGEN if >0 to re-validate the CV methods
            # on PERL510 (>0 + <subgeneration)
            debug( gv => "GV::save &$fullname..." );
            $cvsym = $gvcv->save($fullname);

            # backpatch "$sym = gv_fetchpv($name, GV_ADD, SVt_PV)" to SVt_PVCV
            if ( $cvsym =~ /get_cv/ ) {
                if ( !$B::C::xsub{$package} and B::C::in_static_core( $package, $gvname ) ) {
                    my $in_gv;
                    for ( @{ init()->{current} } ) {
                        if ($in_gv) {
                            s/^.*\Q$sym\E.*=.*;//;
                            s/GvGP_set\(\Q$sym\E.*;//;
                        }
                        if (/^\Q$sym = gv_fetchpv($gvname, GV_ADD, SVt_PV);\E/) {
                            s/^\Q$sym = gv_fetchpv($gvname, GV_ADD, SVt_PV);\E/$sym = gv_fetchpv($gvname, GV_ADD, SVt_PVCV);/;
                            $in_gv++;
                            debug( gv => "removed $sym GP assignments $origname (core CV)" );
                        }
                    }
                    init()->sadd( "GvCV_set(%s, (CV*)SvREFCNT_inc(%s));", $sym, $cvsym );
                }
                elsif ( $B::C::xsub{$package} ) {

                    # must save as a 'stub' so newXS() has a CV to populate later in dl_init()
                    debug( gv => "save stub CvGV for $sym GP assignments $origname (XS CV)" );
                    my $get_cv = get_cv_string( $oname ne "__ANON__" ? $origname : $fullname, "GV_ADD" );
                    init2()->sadd( "GvCV_set(%s, (CV*)SvREFCNT_inc_simple_NN(%s));", $sym, $get_cv );
                    init2()->sadd( "if ((sv = (SV*)%s))", $get_cv );
                    init2()->sadd( "    GvCV_set(%s, (CV*)SvREFCNT_inc_simple_NN(sv));", $sym );
                }
                else {
                    init()->sadd( "GvCV_set(%s, (CV*)(%s));", $sym, $cvsym );
                }

                if ( $gvcv->XSUBANY ) {

                    # some XSUB's set this field. but which part?
                    my $xsubany = $gvcv->XSUBANY;
                    if ( $package =~ /^DBI::(common|db|dr|st)/ ) {

                        # DBI uses the any_ptr for dbi_ima_t *ima, and all dr,st,db,fd,xx handles
                        # for which several ptrs need to be patched. #359
                        # the ima is internal only
                        my $dr = $1;
                        debug( cv => "eval_pv: DBI->_install_method(%s-) (XSUBANY=0x%x)", $fullname, $xsubany );
                        init2()->add_eval(
                            sprintf(
                                "DBI->_install_method('%s', 'DBI.pm', \$DBI::DBI_methods{%s}{%s})",
                                $fullname, $dr, $fullname
                            )
                        );
                    }
                    elsif ( $package eq 'Tie::Hash::NamedCapture' ) {

                        # pretty high _ALIAS CvXSUBANY.any_i32 values
                    }
                    else {
                        # try if it points to an already registered symbol
                        my $anyptr = objsym( \$xsubany );    # ...refactored...
                        if ( $anyptr and $xsubany > 1000 ) { # not a XsubAliases
                            init2()->sadd( "CvXSUBANY(GvCV(%s)).any_ptr = &%s;", $sym, $anyptr );
                        }    # some heuristics TODO. long or ptr? TODO 32bit
                        elsif ( $xsubany > 0x100000 and ( $xsubany < 0xffffff00 or $xsubany > 0xffffffff ) ) {
                            if ( $package eq 'POSIX' and $gvname =~ /^is/ ) {

                                # need valid XSANY.any_dptr
                                init2()->sadd( "CvXSUBANY(GvCV(%s)).any_dptr = (void*)&%s;", $sym, $gvname );
                            }
                            elsif ( $package eq 'List::MoreUtils' and $gvname =~ /_iterator$/ ) {    # should be only the 2 iterators
                                init2()->sadd( "CvXSUBANY(GvCV(%s)).any_ptr = (void*)&XS_List__MoreUtils__%s;", $sym, $gvname );
                            }
                            else {
                                verbose( sprintf( "TODO: Skipping %s->XSUBANY = 0x%x", $fullname, $xsubany ) );
                                init2()->sadd( "/* TODO CvXSUBANY(GvCV(%s)).any_ptr = 0x%lx; */", $sym, $xsubany );
                            }
                        }
                        elsif ( $package eq 'Fcntl' ) {

                            # S_ macro values
                        }
                        else {
                            # most likely any_i32 values for the XsubAliases provided by xsubpp
                            init2()->sadd( "/* CvXSUBANY(GvCV(%s)).any_i32 = 0x%x; XSUB Alias */", $sym, $xsubany );
                        }
                    }
                }
            }
            elsif ( $cvsym =~ /^(cv|&sv_list)/ ) {
                init()->sadd( "GvCV_set(%s, (CV*)(%s));", $sym, $cvsym );
            }
            else {
                WARN("wrong CvGV for $sym $origname: $cvsym") if debug('gv') or verbose();
            }
        }

        # special handling for backref magic
        if ( $cvsym and $cvsym !~ /(get_cv|NULL|lexwarn)/ and $gv->MAGICAL ) {
            my @magic = $gv->MAGIC;
            foreach my $mg (@magic) {
                next unless $mg->TYPE eq '<';
                init()->sadd( "sv_magic((SV*)%s, (SV*)%s, '<', 0, 0);", $sym, $cvsym );
                init()->sadd( "CvCVGV_RC_off(%s);", $cvsym );
            }
        }
    }

    return;
}

sub save_gv_format {
    my ( $gv, $fullname, $sym ) = @_;

    my $gvform = $gv->FORM;
    return unless $gvform && $$gvform;

    $gvform->save($fullname);
    init()->sadd( "GvFORM(%s) = (CV*)s\\_%x;", $sym, $$gvform );
    init()->sadd( "SvREFCNT_inc(s\\_%x);", $$gvform );

    return;
}

sub save_gv_sv {

    my ( $gv, $fullname, $sym, $package, $gvname ) = @_;

    my $gvsv = $gv->SV;
    return unless $$gvsv;

    my $gvname = $gv->NAME;

    debug( gv => "GV::save \$" . $sym . " $gvsv" );

    if ( my $pl_core_sv = $CORE_SVS->{$fullname} ) {
        savesym( $gvsv, $pl_core_sv );
    }

    if ( $gvname eq 'VERSION' and $B::C::xsub{$package} and $gvsv->FLAGS & SVf_ROK ) {
        debug( gv => "Strip overload from $package\::VERSION, fails to xs boot (issue 91)" );
        my $rv     = $gvsv->object_2svref();
        my $origsv = $$rv;
        no strict 'refs';
        ${$fullname} = "$origsv";
        svref_2object( \${$fullname} )->save($fullname);
    }
    else {
        $gvsv->save($fullname);    #even NULL save it, because of gp_free nonsense
                                   # we need sv magic for the core_svs (PL_rs -> gv) (#314)

        # Output record separator https://code.google.com/archive/p/perl-compiler/issues/318
        return if $gvname eq "\\";

        if ( exists $CORE_SVS->{"main::$gvname"} ) {
            $gvsv->save_magic($fullname) if ref($gvsv) eq 'B::PVMG';
            init()->sadd( "SvREFCNT(s\\_%x) += 1;", $$gvsv );
        }
    }
    init()->sadd( "GvSVn(%s) = (SV*)s\\_%x;", $sym, $$gvsv );
    if ( $fullname eq 'main::$' ) {    # $$ = PerlProc_getpid() issue #108
        debug( gv => "  GV $sym \$\$ perlpid" );
        init()->sadd( "sv_setiv(GvSV(%s), (IV)PerlProc_getpid());", $sym );
    }
    debug( gv => "GV::save \$$fullname" );

    return;
}

sub save_gv_av {
    my ( $gv, $fullname, $sym ) = @_;

    my $gvav = $gv->AV;
    return 'NULL' unless $gvav && $$gvav;

    $gvav->save($fullname);
    init()->sadd( "GvAV(%s) = s\\_%x;", $sym, $$gvav );
    if ( $fullname eq 'main::-' ) {
        init()->sadd( "AvFILLp(s\\_%x) = -1;", $$gvav );
        init()->sadd( "AvMAX(s\\_%x) = -1;",   $$gvav );
    }

    return;
}

sub save_gv_hv {
    my ( $gv, $fullname, $sym, $gvname ) = @_;

    my $gvhv = $gv->HV;
    return unless $gvhv && $$gvhv;

    # Handle HV exceptions first...
    return if $fullname eq 'main::ENV' or $fullname eq 'main::INC';    # do not save %ENV

    debug( gv => "GV::save \%$fullname" );
    if ( $fullname eq 'main::!' ) {                                    # force loading Errno
        init()->add("/* \%! force saving of Errno */");
        mark_package( 'Errno', 1 );                                    # B::C needs Errno but does not import $!
    }
    elsif ( $fullname eq 'main::+' or $fullname eq 'main::-' ) {
        init()->sadd( "/* %%%s force saving of Tie::Hash::NamedCapture */", $gvname );
        svref_2object( \&{'Tie::Hash::NamedCapture::bootstrap'} )->save;
        mark_package( 'Tie::Hash::NamedCapture', 1 );
    }

    # skip static %Encode::Encoding since 5.20. GH #200. sv_upgrade cannot upgrade itself.
    # Let it be initialized by boot_Encode/Encode_XSEncodingm with exceptions.
    # GH #200 and t/testc.sh 75
    if ( $fullname eq 'Encode::Encoding' ) {
        debug( gv => "skip some %Encode::Encoding - XS initialized" );
        my %tmp_Encode_Encoding = %Encode::Encoding;
        %Encode::Encoding = ();    # but we need some non-XS encoding keys
        foreach my $k (qw(utf8 utf-8-strict Unicode Internal Guess)) {
            $Encode::Encoding{$k} = $tmp_Encode_Encoding{$k} if exists $tmp_Encode_Encoding{$k};
        }
        $gvhv->save($fullname);
        init()->add("/* deferred some XS enc pointers for \%Encode::Encoding */");
        init()->sadd( "GvHV(%s) = s\\_%x;", $sym, $$gvhv );

        %Encode::Encoding = %tmp_Encode_Encoding;
        return;
    }

    $gvhv->save($fullname);
    init()->sadd( "GvHV(%s) = s\\_%x;", $sym, $$gvhv );

    return;
}

sub save_gv_io {
    my ( $gv, $fullname, $sym ) = @_;

    my $gvio = $gv->IO;
    return unless $$gvio;

    my $is_data;
    if ( $fullname eq 'main::DATA' or ( $fullname =~ m/::DATA$/ ) ) {
        no strict 'refs';
        my $fh = *{$fullname}{IO};
        use strict 'refs';
        $is_data = 'is_DATA';
        $gvio->save_data( $sym, $fullname, <$fh> ) if $fh->opened;
    }

    $gvio->save( $fullname, $is_data );
    init()->sadd( "GvIOp(%s) = s\\_%x;", $sym, $$gvio );

    return;
}

sub gv_fetchpv_string {
    my ( $name, $flags, $type ) = @_;
    warn 'undefined flags' unless defined $flags;
    warn 'undefined type'  unless defined $type;
    my ( $cname, $cur, $utf8 ) = strlen_flags($name);

    $flags .= length($flags) ? "|$utf8" : $utf8 if $utf8;
    return "gv_fetchpvn_flags($cname, $cur, $flags, $type)";
}

sub savecv {
    my $gv      = shift;
    my $package = $gv->STASH->NAME;
    my $name    = $gv->NAME;
    my $cv      = $gv->CV;
    my $sv      = $gv->SV;
    my $av      = $gv->AV;
    my $hv      = $gv->HV;

    # We Should NEVER compile B::C packages so if we get here, it's a bug.
    # TODO: Currently breaks xtestc/0350.t and xtestc/0371.t if we make this a die.
    return if $package eq 'B::C';

    my $fullname = $package . "::" . $name;
    debug( gv => "Checking GV *%s 0x%x\n", cstring($fullname), ref $gv ? $$gv : 0 ) if verbose();

    # We may be looking at this package just because it is a branch in the
    # symbol table which is on the path to a package which we need to save
    # e.g. this is 'Getopt' and we need to save 'Getopt::Long'
    #
    return if ( $package ne 'main' and !is_package_used($package) );
    return if ( $package eq 'main'
        and $name =~ /^([^\w].*|_\<.*|INC|ARGV|SIG|ENV|BEGIN|main::|!)$/ );

    debug( gv => "Used GV \*$fullname 0x%x", ref $gv ? $$gv : 0 );
    return unless ( $$cv || $$av || $$sv || $$hv || $gv->IO || $gv->FORM );
    if ( $$cv and $name eq 'bootstrap' and $cv->XSUB ) {

        #return $cv->save($fullname);
        debug( gv => "Skip XS \&$fullname 0x%x", ref $cv ? $$cv : 0 );
        return;
    }
    if (
        $$cv and B::C::in_static_core( $package, $name ) and ref($cv) eq 'B::CV'    # 5.8,4 issue32
        and $cv->XSUB
      ) {
        debug( gv => "Skip internal XS $fullname" );

        # but prevent it from being deleted
        unless ( $B::C::dumped_package{$package} ) {

            #$B::C::dumped_package{$package} = 1;
            mark_package( $package, 1 );
        }
        return;
    }

    # load utf8 and bytes on demand.
    if ( my $newgv = force_heavy( $package, $fullname ) ) {
        $gv = $newgv;
    }

    # XXX fails and should not be needed. The B::C part should be skipped 9 lines above, but be defensive
    return if $fullname eq 'B::walksymtable' or $fullname eq 'B::C::walksymtable';

    # Config is marked on any Config symbol. TIE and DESTROY are exceptions,
    # used by the compiler itself
    if ( $name eq 'Config' ) {
        mark_package( 'Config', 1 ) if !is_package_used('Config');
    }

    $B::C::dumped_package{$package} = 1 if !exists $B::C::dumped_package{$package} and $package !~ /::$/;
    debug( gv => "Saving GV \*$fullname 0x%x", ref $gv ? $$gv : 0 );
    $gv->save($fullname);
}

sub get_savefields {
    my ( $gv, $fullname, $filter ) = @_;

    my $gvname = $gv->NAME;

    # default savefields
    my $savefields = Save_HV | Save_AV | Save_SV | Save_CV | Save_FORM | Save_IO;

    $savefields = 0 if $gv->save_egv();
    $savefields = 0 if $gvname =~ /::$/;
    $savefields = 0 if $gv->is_empty();

    my $gp = $gv->GP;
    $savefields = 0 if !$gp or !exists $gptable{ 0 + $gp };

    # some non-alphabetic globs require some parts to be saved
    # ( ex. %!, but not $! )
    if ( ref($gv) eq 'B::STASHGV' and $gvname !~ /::$/ ) {

        # https://code.google.com/archive/p/perl-compiler/issues/79 - Only save stashes for stashes.
        $savefields = 0;
    }
    elsif ( $gvname !~ /^([^A-Za-z]|STDIN|STDOUT|STDERR|ARGV|SIG|ENV)$/ ) {
        $savefields = Save_HV | Save_AV | Save_SV | Save_CV | Save_FORM | Save_IO;
    }
    elsif ( $fullname eq 'main::!' ) {    #Errno
        $savefields = Save_HV | Save_SV | Save_CV;
    }
    elsif ( $fullname eq 'main::ENV' or $fullname eq 'main::SIG' ) {
        $savefields = Save_AV | Save_SV | Save_CV | Save_FORM | Save_IO;
    }
    elsif ( $fullname eq 'main::ARGV' ) {
        $savefields = Save_HV | Save_SV | Save_CV | Save_FORM | Save_IO;
    }
    elsif ( $fullname =~ /^main::STD(IN|OUT|ERR)$/ ) {
        $savefields = Save_FORM | Save_IO;
    }
    elsif ( $fullname eq 'main::_' or $fullname eq 'main::@' ) {
        $savefields = 0;
    }

    # avoid overly dynamic POSIX redefinition warnings: GH #335, #345
    if ( $fullname =~ m/^POSIX::M/ or $fullname eq 'attributes::bootstrap' ) {
        $savefields &= ~Save_CV;
    }

    # compute filter
    $filter = normalize_filter( $filter, $fullname );

    # apply filter
    if ( $filter and $filter =~ qr{^[0-9]$} ) {
        $savefields &= ~$filter;
    }

    my $is_gvgp    = $gv->isGV_with_GP;
    my $is_coresym = $gv->is_coresym();
    if ( !$is_gvgp or $is_coresym ) {
        $savefields &= ~Save_FORM;
        $savefields &= ~Save_IO;
    }

    $savefields |= Save_FILE if ( $is_gvgp and !$is_coresym && ( !$B::C::stash or $fullname !~ /::$/ ) );

    $savefields &= Save_SV if $gvname eq '\\';

    return $savefields;
}

sub normalize_filter {
    my ( $filter, $fullname ) = @_;

    if ( $filter and $filter =~ m/ :pad/ ) {
        $filter = 0;
    }

    # no need to assign any SV/AV/HV to them (172)
    if ( $fullname =~ /^DynaLoader::dl_(require_symbols|resolve_using|librefs)/ ) {
        $filter = Save_SV | Save_AV | Save_HV;
    }
    if ( $fullname =~ /^main::([1-9])$/ ) {    # ignore PV regexp captures with -O2
        $filter = Save_SV;
    }

    return $filter;
}
1;
