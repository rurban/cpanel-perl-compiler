package B::CV;

use strict;

use B::C::Flags ();

use B qw/cstring svref_2object CVf_ANON CVf_ANONCONST CVf_CONST main_cv SVf_ROK SVp_POK SVf_IOK SVf_UTF8 SVs_PADSTALE CVf_WEAKOUTSIDE/;
use B::C::Config;
use B::C::Decimal qw/get_integer_value/;
use B::C::Save qw/savepvn constpv/;
use B::C::Save::Hek qw/save_shared_he/;
use B::C::File qw/init init2 decl svsect xpvcvsect symsect/;
use B::C::Helpers qw/get_cv_string strlen_flags set_curcv/;
use B::C::Helpers::Symtable qw/objsym savesym delsym/;

my (%cvforward);
my $cv_index      = 0;
my $initsub_index = 0;
my $anonsub_index = 0;

sub is_lexsub {
    my ( $cv, $gv ) = @_;

    # logical shortcut perl5 bug since ~ 5.19: testcc.sh 42
    return ( ( !$gv or ref($gv) eq 'B::SPECIAL' ) and $cv->can('NAME_HEK') ) ? 1 : 0;
}

sub is_phase_name {
    $_[0] =~ /^(BEGIN|INIT|UNITCHECK|CHECK|END)$/ ? 1 : 0;
}

sub Dummy_initxs { }

sub do_save {
    my ( $cv, $origname ) = @_;
    my $sym;
    my $gv = $cv->GV;
    my ( $cvname, $cvstashname, $fullname, $isutf8 );
    $fullname = '';
    my $CvFLAGS = $cv->CvFLAGS;
    if ( $gv and $$gv ) {
        $cvstashname = $gv->STASH->NAME;
        $cvname      = $gv->NAME;
        $isutf8      = ( $gv->FLAGS & SVf_UTF8 ) || ( $gv->STASH->FLAGS & SVf_UTF8 );
        $fullname    = $cvstashname . '::' . $cvname;

        # XXX gv->EGV does not really help here
        if ( $cvname eq '__ANON__' ) {
            if ($origname) {
                debug( cv => "CV with empty PVGV %s -> %s", $fullname, $origname );
                $cvname = $fullname = $origname;
                $cvname =~ s/^\Q$cvstashname\E::(.*)( :pad\[.*)?$/$1/ if $cvstashname;
                $cvname =~ s/^.*:://;
                if ( $cvname =~ m/ :pad\[.*$/ ) {
                    $cvname =~ s/ :pad\[.*$//;
                    $cvname = '__ANON__' if is_phase_name($cvname);
                    $fullname = $cvstashname . '::' . $cvname;
                }
                debug( cv => "empty -> %s", $cvname );
            }
            else {
                $cvname = $gv->EGV->NAME;
                debug( cv => "CV with empty PVGV %s -> %s::%s", $fullname, $cvstashname, $cvname );
                $fullname = $cvstashname . '::' . $cvname;
            }
        }

        debug(
            cv => "CV 0x%x as PVGV 0x%x %s CvFLAGS=0x%x\n",
            $$cv, $$gv, $fullname, $CvFLAGS
        );

        return '0' unless B::C::Optimizer::UnusedPackages::package_was_compiled_in($cvstashname);
        $CvFLAGS &= ~0x400;    # no CVf_CVGV_RC otherwise we cannot set the GV
    }
    elsif ( $cv->is_lexsub($gv) ) {
        $fullname = $cv->NAME_HEK;
        $fullname = '' unless defined $fullname;
        $isutf8   = $cv->FLAGS & SVf_UTF8;
        debug( cv => "CV lexsub NAME_HEK $fullname" );
        if ( $fullname =~ /^(.*)::(.*?)$/ ) {
            $cvstashname = $1;
            $cvname      = $2;
        }
    }
    $cvstashname = '' unless defined $cvstashname;
    my $flags = $isutf8 ? 'SVf_UTF8' : '';

    # XXX TODO need to save the gv stash::AUTOLOAD if exists
    my $root   = $cv->ROOT;
    my $cvxsub = $cv->XSUB;
    my $isconst;
    {
        no strict 'subs';
        $isconst = $CvFLAGS & CVf_CONST;
    }

    if ( !$isconst && $cvxsub && ( $cvname ne "INIT" ) ) {
        my $egv       = $gv->EGV;
        my $stashname = $egv->STASH->NAME;
        $fullname = $stashname . '::' . $cvname;
        if ( $cvname eq "bootstrap" and !$B::C::xsub{$stashname} ) {
            my $file = $gv->FILE;
            decl()->add("/* bootstrap $file */");
            verbose("Bootstrap $stashname $file");

            # Without DynaLoader we must boot and link static
            if ( !$B::C::Flags::Config{usedl} ) {
                $B::C::xsub{$stashname} = 'Static';
            }

            # if it not isa('DynaLoader'), it should hopefully be XSLoaded
            # ( attributes being an exception, of course )
            elsif ( !UNIVERSAL::isa( $stashname, 'DynaLoader' ) ) {
                my $stashfile = $stashname;
                $stashfile =~ s/::/\//g;
                if ( $file =~ /XSLoader\.pm$/ ) {    # almost always the case
                    $file = $INC{ $stashfile . ".pm" };
                }
                unless ($file) {                     # do the reverse as DynaLoader: soname => pm
                    my ($laststash) = $stashname =~ /::([^:]+)$/;
                    $laststash = $stashname unless $laststash;
                    my $sofile = "auto/" . $stashfile . '/' . $laststash . '\\.' . $B::C::Flags::Config{dlext};
                    for (@DynaLoader::dl_shared_objects) {
                        if (m{^(.+/)$sofile$}) {
                            $file = $1 . $stashfile . ".pm";
                            last;
                        }
                    }
                }
                $B::C::xsub{$stashname} = 'Dynamic-' . $file;
                B::C::force_saving_xsloader();
            }
            else {
                $B::C::xsub{$stashname} = 'Dynamic';
            }

            # INIT is removed from the symbol table, so this call must come
            # from PL_initav->save. Re-bootstrapping  will push INIT back in,
            # so nullop should be sent.
            debug( sub => $fullname );
            return qq/NULL/;
        }

        debug( 'sub' => $fullname );
        unless ( B::C::in_static_core( $stashname, $cvname ) ) {
            no strict 'refs';
            debug( cv => "XSUB $fullname CV 0x%x\n", $$cv );
            svref_2object( \*{"$stashname\::bootstrap"} )->save
              if $stashname;    # and defined ${"$stashname\::bootstrap"};
                                # delsym($cv);
            return get_cv_string( $fullname, $flags );
        }
        else {                  # Those cvs are already booted. Reuse their GP.
                                # Esp. on windows it is impossible to get at the XS function ptr
            debug( cv => "core XSUB $fullname CV 0x%x\n", $$cv );
            return get_cv_string( $fullname, $flags );
        }
    }
    if ( !$isconst && $cvxsub && $cvname && $cvname eq "INIT" ) {
        no strict 'refs';
        debug( sub => $fullname );
        return svref_2object( \&Dummy_initxs )->save;
    }

    if (
            $isconst
        and !is_phase_name($cvname)
        and !( $CvFLAGS & SVs_PADSTALE )
        and !( $CvFLAGS & CVf_WEAKOUTSIDE )
        and !( $fullname && $fullname =~ qr{^File::Glob::GLOB} and ( $CvFLAGS & ( CVf_ANONCONST | CVf_CONST ) ) )

        # TODO: check if patch from e11e3a2 for B::SPECIAL is still required
        #    and ref($gv) ne 'B::SPECIAL'
      ) {    # skip const magic blocks (Attribute::Handlers)
        my $stash = $gv->STASH;
        my $sv    = $cv->XSUBANY;
        debug( cv => "CV CONST 0x%x %s::%s -> 0x%x as %s\n", $$gv, $cvstashname, $cvname, $sv, ref $sv );

        # debug( sub => "%s::%s\n", $cvstashname, $cvname);
        my $stsym = $stash->save;
        my $name  = cstring($cvname);

        # need to check 'Encode::XS' constant encodings
        # warn "$sv CONSTSUB $name";
        if ( ( ref($sv) eq 'B::IV' or ref($sv) eq 'B::PVMG' ) and $sv->FLAGS & SVf_ROK ) {
            my $rv = $sv->RV;
            if ( $rv->FLAGS & ( SVp_POK | SVf_IOK ) and $rv->IVX > LOWEST_IMAGEBASE ) {

                # TODO: shouldn't be calling a private.
                B::PVMG::_patch_dlsym( $rv, $fullname, $rv->IVX );
            }
        }

        # TODO Attribute::Handlers #171, test 176
        if ( ref($sv) =~ m/^(SCALAR|ARRAY|HASH|CODE|REF)$/ ) {

            # Save XSUBANY, maybe ARRAY or HASH also?
            debug( cv => "SCALAR const sub $cvstashname::$cvname -> $sv" );
            my $vsym = svref_2object( \$sv )->save;
            my $cvi  = "cv" . $cv_index++;
            decl()->add("Static CV* $cvi;");
            init()->add("$cvi = newCONSTSUB( $stsym, $name, (SV*)$vsym );");
            return $cvi;
        }
        elsif ( $sv and ref($sv) =~ /^B::[NRPI]/ ) {
            my $vsym = $sv->save;
            my $cvi  = "cv" . $cv_index++;
            decl()->add("Static CV* $cvi;");
            init()->add("$cvi = newCONSTSUB( $stsym, $name, (SV*)$vsym );");
            return $cvi;
        }
        else {
            verbose("Warning: Undefined const sub $cvstashname::$cvname -> $sv");
        }

    }

    # This define is forwarded to the real sv below
    # The new method, which saves a SV only works since 5.10 (? Does not work in newer perls)
    my $sv_ix = svsect()->index + 1;
    my $xpvcv_ix;
    svsect()->add("CVIX$sv_ix");
    svsect()->debug( "&" . $fullname, $cv );
    $xpvcv_ix = xpvcvsect()->index + 1;
    xpvcvsect()->add("XPVCVIX$xpvcv_ix");

    # Save symbol now so that GvCV() doesn't recurse back to us via CvGV()
    $sym = savesym( $cv, "&sv_list[$sv_ix]" );

    debug( cv => "saving %s CV 0x%x as %s", $fullname, $$cv, $sym );

    # fixme: interesting have a look at it
    if ( $fullname eq 'utf8::SWASHNEW' ) {    # bypass utf8::AUTOLOAD, a new 5.13.9 mess
        B::C::load_utf8_heavy();
    }

    # fixme: can probably be removed
    if ( $fullname eq 'IO::Socket::SSL::SSL_Context::new' ) {
        if ( $IO::Socket::SSL::VERSION ge '1.956' and $IO::Socket::SSL::VERSION lt '1.995' ) {

            # See https://code.google.com/p/perl-compiler/issues/detail?id=317
            # https://rt.cpan.org/Ticket/Display.html?id=95452
            WARN( "Warning: Your IO::Socket::SSL version $IO::Socket::SSL::VERSION is unsupported to create\n" . "  a server. You need to upgrade IO::Socket::SSL to at least 1.995 [CPAN #95452]" );
        }
    }

    if ( !$$root && !$cvxsub ) {
        my $reloaded;
        if ( $fullname eq 'Coro::State::_jit' ) {    # 293
                                                     # need to force reload the jit src
            my ($pl) = grep { m|^Coro/jit-| } keys %INC;
            if ($pl) {
                delete $INC{$pl};
                require $pl;
                $cv       = svref_2object( \&{$fullname} );
                $reloaded = 1;
            }
        }
        if ($reloaded) {
            $gv = $cv->GV;
            debug(
                cv => "Redefined CV 0x%x as PVGV 0x%x %s CvFLAGS=0x%x\n",
                $$cv, $$gv, $fullname, $CvFLAGS
            );
            $sym    = savesym( $cv, $sym );
            $root   = $cv->ROOT;
            $cvxsub = $cv->XSUB;
        }
    }
    if ( !$$root && !$cvxsub ) {
        if ( my $auto = B::C::try_autoload( $cvstashname, $cvname ) ) {
            if ( ref $auto eq 'B::CV' ) {    # explicit goto or UNIVERSAL
                $root   = $auto->ROOT;
                $cvxsub = $auto->XSUB;
                if ($$auto) {

                    # XXX This has now created a wrong GV name!
                    my $oldcv = $cv;
                    $cv = $auto;             # This is new. i.e. via AUTOLOAD or UNIVERSAL, in another stash
                    my $gvnew = $cv->GV;
                    if ($$gvnew) {
                        if ( $cvstashname ne $gvnew->STASH->NAME or $cvname ne $gvnew->NAME ) {    # UNIVERSAL or AUTOLOAD
                            my $newname = $gvnew->STASH->NAME . "::" . $gvnew->NAME;
                            debug( sub => " New $newname autoloaded. remove old cv" );
                            svsect()->remove;
                            xpvcvsect()->remove;
                            delsym($oldcv);

                            no strict 'refs';
                            my $newsym = svref_2object( \*{$newname} )->save;
                            my $cvsym = defined objsym($cv) ? objsym($cv) : $cv->save($newname);
                            if ( my $oldsym = objsym($gv) ) {
                                debug( gv => "Alias polluted $oldsym to $newsym" );
                                init()->add("$oldsym = $newsym;");
                                delsym($gv);
                            }    # else {
                                 #init()->add("GvCV_set(gv_fetchpv(\"$fullname\", GV_ADD, SVt_PV), (CV*)NULL);");
                                 #}
                            return $cvsym;
                        }
                    }
                    $sym = savesym( $cv, "&sv_list[$sv_ix]" );    # GOTO
                    verbose("$fullname GOTO");
                }
            }
            else {
                # Recalculated root and xsub
                $root   = $cv->ROOT;
                $cvxsub = $cv->XSUB;
                my $gv = $cv->GV;
                if ($$gv) {
                    if ( $cvstashname ne $gv->STASH->NAME or $cvname ne $gv->NAME ) {    # UNIVERSAL or AUTOLOAD
                        my $newname = $gv->STASH->NAME . "::" . $gv->NAME;
                        verbose("Recalculated root and xsub $newname. remove old cv");
                        svsect()->remove;
                        xpvcvsect()->remove;
                        delsym($cv);
                        return $cv->save($newname);
                    }
                }
            }
            if ( $$root || $cvxsub ) {
                debug( cv => "Successful forced autoload" ) if verbose();
            }
        }
    }
    if ( !$$root ) {
        if ( exists &$fullname ) {
            debug( sub => "Warning: Empty &" . $fullname );
            init()->add("/* empty CV $fullname */") if verbose() or debug('sub');
        }
        elsif ( $cv->is_lexsub($gv) ) {

            # need to find the attached lexical sub (#130 + #341) at run-time
            # in the PadNAMES array. So keep the empty PVCV
            debug( sub => "lexsub &" . $fullname . " saved as empty $sym" );
        }
        else {
            debug( sub => "Warning: &" . $fullname . " not found" );
            init()->add("/* CV $fullname not found */") if verbose() or debug('sub');

            # This block broke test 15, disabled
            if ( $sv_ix == svsect()->index ) {    # can delete, is the last SV
                debug( cv => "No definition for sub $fullname (unable to autoload), skip CV[$sv_ix]" );
                svsect()->remove;
                xpvcvsect()->remove;
                delsym($cv);

                # Empty CV (methods) must be skipped not to disturb method resolution
                # (e.g. t/testm.sh POSIX)
                return '0';
            }
            else {
                # interim &AUTOLOAD saved, cannot delete. e.g. Fcntl, POSIX
                WARN("No definition for sub $fullname (unable to autoload), stub CV[$sv_ix]")
                  if debug('cv')
                  or verbose();

                # continue, must save the 2 symbols from above
            }
        }
    }

    my $startfield = 0;
    my $padlist    = $cv->PADLIST;
    set_curcv($cv);
    my $padlistsym = 'NULL';
    my $pv         = $cv->PV;
    my $xsub       = 0;
    my $xsubany    = "{0}";
    if ($$root) {
        debug(
            gv => "saving op tree for CV 0x%x, root=0x%x\n",
            $$cv, $$root
        ) if debug('cv');
        my $ppname = "";
        if ( $cv->is_lexsub($gv) ) {
            my $name = $cv->can('NAME_HEK') ? $cv->NAME_HEK : "anonlex";
            $ppname   = "pp_lexsub_" . $name;
            $fullname = "<lex>" . $name;
        }
        elsif ( $gv and $$gv ) {
            my ( $stashname, $gvname );
            $stashname = $gv->STASH->NAME;
            $gvname    = $gv->NAME;
            $fullname  = $stashname . '::' . $gvname;
            $ppname    = ( ${ $gv->FORM } == $$cv ) ? "pp_form_" : "pp_sub_";
            if ( $gvname ne "__ANON__" ) {
                $ppname .= ( $stashname eq "main" ) ? $gvname : "$stashname\::$gvname";
                $ppname =~ s/::/__/g;
                $ppname =~ s/(\W)/sprintf("0x%x", ord($1))/ge;
                if ( $gvname eq "INIT" ) {
                    $ppname .= "_$initsub_index";
                    $initsub_index++;
                }
            }
        }
        if ( !$ppname ) {
            $ppname = "pp_anonsub_$anonsub_index";
            $anonsub_index++;
        }
        $startfield = B::C::saveoptree( $ppname, $root, $cv->START, $padlist->ARRAY );    # XXX padlist is ignored

        # XXX missing cv_start for AUTOLOAD on 5.8
        $startfield = objsym( $root->next ) unless $startfield;                           # 5.8 autoload has only root
        $startfield = "0" unless $startfield;                                             # XXX either CONST ANON or empty body
        if ($$padlist) {

            # XXX readonly comppad names and symbols invalid
            debug( gv => "saving PADLIST 0x%x for CV 0x%x\n", $$padlist, $$cv )
              if debug('cv');

            # XXX avlen 2
            $padlistsym = $padlist->save( $fullname . ' :pad', $cv );
            debug(
                gv => "done saving %s 0x%x for CV 0x%x\n",
                $padlistsym, $$padlist, $$cv
            ) if debug('cv');

            # do not record a forward for the pad only

            # issue 298: dynamic CvPADLIST(&END) since 5.18 - END{} blocks
            # and #169 and #304 Attribute::Handlers
            init()->add(
                "{ /* &$fullname needs a dynamic padlist */",
                "  PADLIST *pad;",
                "  Newxz(pad, sizeof(PADLIST), PADLIST);",
                "  Copy($padlistsym, pad, sizeof(PADLIST), char);",
                "  CvPADLIST($sym) = pad;",
                "}"
            );
        }
        debug( sub => $fullname );
    }
    elsif ( $cv->is_lexsub($gv) ) {
        ;
    }
    elsif ( !exists &$fullname ) {
        debug( sub => $fullname . " not found" );
        debug( cv  => "No definition for sub $fullname (unable to autoload)" );
        init()->add("/* $fullname not found */") if verbose() or debug('sub');

        # XXX empty CV should not be saved. #159, #235
        # svsect()->remove( $sv_ix );
        # xpvcvsect()->remove( $xpvcv_ix );
        # delsym( $cv );
        symsect()->add("XPVCVIX$xpvcv_ix\t0");
        $CvFLAGS &= ~0x1000;                   # CVf_DYNFILE
        $CvFLAGS &= ~0x400 if $gv and $$gv;    #CVf_CVGV_RC
        symsect()->sadd(
            "CVIX%d\t(XPVCV*)&xpvcv_list[%u], %Lu, 0x%x, {0}",
            $sv_ix, $xpvcv_ix, $cv->REFCNT, $CvFLAGS
        );
        return get_cv_string( $fullname, $flags );
    }

    my $proto = defined $pv ? cstring($pv) : 'NULL';
    my $pvsym = 'NULL';
    my $cur   = defined $pv ? $cv->CUR : 0;
    my $len   = $cur + 1;
    $len++ if B::C::IsCOW($cv);
    $len = 0 if $B::C::const_strings;

    # need to survive cv_undef as there is no protection against static CVs
    my $refcnt = $cv->REFCNT + 1;

    # GV cannot be initialized statically
    my $xcv_outside = ${ $cv->OUTSIDE };
    if ( $xcv_outside == ${ main_cv() } ) {

        # Provide a temp. debugging hack for CvOUTSIDE. The address of the symbol &PL_main_cv
        # is known to the linker, the address of the value PL_main_cv not. This is set later
        # (below) at run-time.
        $xcv_outside = '&PL_main_cv';
    }
    elsif ( ref( $cv->OUTSIDE ) eq 'B::CV' ) {
        $xcv_outside = 0;    # just a placeholder for a run-time GV
    }

    # XXX issue 84: we need to check the cv->PV ptr not the value.
    # "" is different to NULL for prototypes
    $len = $cur ? $cur + 1 : 0;

    # TODO:
    # my $ourstash = "0";  # TODO stash name to bless it (test 16: "main::")

    # cv_undef wants to free it when CvDYNFILE(cv) is true.
    # E.g. DateTime: boot_POSIX. newXS reuses cv if autoloaded. So turn it off globally.
    $CvFLAGS &= ~0x1000;    # CVf_DYNFILE off
    my $xpvc = sprintf

      # stash magic cur len cvstash start root cvgv cvfile cvpadlist     outside outside_seq cvflags cvdepth
      (
        "Nullhv, {0}, %u, {%u}, %s, {%s}, {s\\_%x}, {%s}, %s, {%s}, (CV*)%s, %s, 0x%x, %d",
        $cur, $len, "Nullhv",    #CvSTASH later
        $startfield, $$root,
        "0",                     #GV later
        "NULL",                  #cvfile later (now a HEK)
        $padlistsym,
        $xcv_outside,            #if main_cv set later
        get_integer_value( $cv->OUTSIDE_SEQ ),
        $CvFLAGS,
        $cv->DEPTH
      );

    # repro only with 5.15.* threaded -q (70c0620) Encode::Alias::define_alias
    WARN("lexwarnsym in XPVCV OUTSIDE: $xpvc") if $xpvc =~ /, \(CV\*\)iv\d/;    # t/testc.sh -q -O3 227
    symsect()->add("XPVCVIX$xpvcv_ix\t$xpvc");

    if ($$cv) {

        if ( !$gv or ref($gv) eq 'B::SPECIAL' ) {
            my $lexsub = $cv->can('NAME_HEK') ? $cv->NAME_HEK : "_anonlex_";
            $lexsub = '' unless defined $lexsub;
            debug( gv => "lexsub name $lexsub" );

            my ( $cstring, $cur, $utf8 ) = strlen_flags($lexsub);
            $cur *= -1 if $utf8;

            init()->add(
                "{ /* need a dynamic name hek */",
                sprintf(
                    "  HEK *lexhek = share_hek(savepvn(%s, %d), %d, 0);",
                    $cstring, abs($cur), $cur
                ),
                sprintf( "  CvNAME_HEK_set(s\\_%x, lexhek);", $$cv ),
                "}"
            );
        }
        else {
            my $gvstash = $gv->STASH;

            # defer GvSTASH because with DEBUGGING it checks for GP but
            # there's no GP yet.
            # But with -fstash the gvstash is set later
            init()->sadd(
                "GvXPVGV(s\\_%x)->xnv_u.xgv_stash = s\\_%x;",
                $$cv, $$gvstash
            ) if $gvstash;
            debug( gv => "done saving GvSTASH 0x%x for CV 0x%x\n", $$gvstash, $$cv )
              if $gvstash and debug('cv');

        }
    }
    if ( $cv->OUTSIDE_SEQ ) {
        my $cop = $B::C::File::symtable{ sprintf( "s\\_%x", $cv->OUTSIDE_SEQ ) };
        init()->sadd( "CvOUTSIDE_SEQ(%s) = %s;", $sym, $cop ) if $cop;
    }

    $xcv_outside = ${ $cv->OUTSIDE };
    if ( $xcv_outside == ${ main_cv() } or ref( $cv->OUTSIDE ) eq 'B::CV' ) {

        # patch CvOUTSIDE at run-time
        if ( $xcv_outside == ${ main_cv() } ) {
            init()->add(
                "CvOUTSIDE($sym) = PL_main_cv;",
                "SvREFCNT_inc(PL_main_cv);"
            );
            if ( $padlist && $$padlist ) {
                init()->add("CvPADLIST($sym)->xpadl_outid = CvPADLIST(PL_main_cv)->xpadl_id;");
            }
        }
        else {
            init()->sadd( "CvOUTSIDE(%s) = (CV*)s\\_%x;", $sym, $xcv_outside );
        }
    }
    elsif ( $xcv_outside && ref( $cv->OUTSIDE ) ) {
        my $padl = $cv->OUTSIDE->PADLIST->save;
        init()->sadd( "CvPADLIST(%s)->xpadl_outid = CvPADLIST(s\\_%x)->xpadl_id;", $sym, $xcv_outside );
    }

    if ( $gv and $$gv ) {

        #test 16: Can't call method "FETCH" on unblessed reference. gdb > b S_method_common
        debug( gv => "Saving GV 0x%x for CV 0x%x\n", $$gv, $$cv ) if debug('cv');
        $gv->save;

        init()->sadd( "CvGV_set((CV*)%s, (GV*)%s);", $sym, objsym($gv) );

        # Since 5.13.3 and CvGV_set there are checks that the CV is not RC (refcounted).
        # Assertion "!CvCVGV_RC(cv)" failed: file "gv.c", line 219, function: Perl_cvgv_set
        # We init with CvFLAGS = 0 and set it later, as successfully done in the Bytecode compiler
        if ( $CvFLAGS & 0x0400 ) {    # CVf_CVGV_RC
            debug(
                cv => "CvCVGV_RC turned off. CV flags=0x%x %s CvFLAGS=0x%x \n",
                $cv->FLAGS, debug('flags') ? $cv->flagspv : "", $CvFLAGS & ~0x400
            );
            init()->sadd(
                "CvFLAGS((CV*)%s) = 0x%x; %s", $sym, $CvFLAGS,
                debug('flags') ? "/* " . $cv->flagspv . " */" : ""
            );
        }
        init()->add("CvSTART($sym) = $startfield;");    # XXX TODO someone is overwriting CvSTART also

        debug(
            gv => "done saving GV 0x%x for CV 0x%x\n",
            $$gv, $$cv
        ) if debug('cv');
    }

    my $file = $cv->FILE();
    if ( $B::C::const_strings && length $file ) {
        init()->sadd( "CvFILE(%s) = (char *) %s;", $sym, constpv($file) );
    }
    else {
        init()->sadd( "CvFILE(%s) = %s;", $sym, cstring( $cv->FILE ) );
    }

    my $stash = $cv->STASH;
    if ( $$stash and ref($stash) ) {

        # init()->add("/* saving STASH $fullname */\n" if debug('cv');
        $stash->save($fullname);

        # $sym fixed test 27
        init2()->sadd( "CvSTASH_set((CV*)%s, s\\_%x);", $sym, $$stash );

        #init()->sadd( "SvREFCNT_inc(%s);", $sym ); # fixes mro/basic.t and more

        # 5.18 bless does not inc sv_objcount anymore. broken by ddf23d4a1ae (#208)
        # We workaround this 5.18 de-optimization by adding it if at least a DESTROY
        # method exists.
        init2()->add("++PL_sv_objcount;") if $cvname eq 'DESTROY';

        debug( gv => "done saving STASH 0x%x for CV 0x%x\n", $$stash, $$cv ) if debug('cv');
    }
    my $magic = $cv->MAGIC;
    if ( $magic and $$magic ) {
        $cv->save_magic($fullname);    # XXX will this work?
    }

    symsect()->sadd(
        "CVIX%d\t(XPVCV*)&xpvcv_list[%u], %Lu, 0x%x, {0}",
        $sv_ix, $xpvcv_ix, $cv->REFCNT, $cv->FLAGS
    );

    if ($cur) {
        debug( cv => "Saving CV proto %s for CV $sym 0x%x\n", cstring($pv), $$cv );
    }

    # issue 84: empty prototypes sub xx(){} vs sub xx{}
    if ( defined $pv ) {
        $pvsym = save_shared_he($pv);
        if ($cur) {
            init()->sadd( "SvPVX(&sv_list[%d]) = %s->shared_he_hek.hek_key;", $sv_ix, $pvsym );

            #define HEK_BASESIZE               STRUCT_OFFSET(HEK, hek_key[0])
        }
        elsif ( !$B::C::const_strings ) {    # not static, they are freed when redefined
            init()->sadd(
                "SvPVX(&sv_list[%d]) = savepvn(%s, %u);",
                $sv_ix, $proto, $cur
            );
        }
        else {
            init()->sadd(
                "SvPVX(&sv_list[%d]) = %s;",
                $sv_ix, $proto
            );
        }
    }
    $cv->OUTSIDE->save if $xcv_outside;
    return $sym;
}

1;
