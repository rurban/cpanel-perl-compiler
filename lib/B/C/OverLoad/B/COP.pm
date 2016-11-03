package B::COP;

use strict;

use B qw/cstring/;
use B::C::Config;
use B::C::File qw/init copsect decl/;
use B::C::Save qw/constpv savestashpv/;
use B::C::Decimal qw/get_integer_value/;
use B::C::Helpers::Symtable qw/savesym objsym/;
use B::C::Helpers qw/read_utf8_string strlen_flags/;

my %cophhtable;
my %copgvtable;

sub save {
    my ( $op, $level ) = @_;

    my $sym = objsym($op);
    return $sym if defined $sym;

    # TODO: if it is a nullified COP we must save it with all cop fields!
    debug( cops => "COP: line %d file %s\n", $op->line, $op->file );

    my $ix = copsect()->add('FAKE_COP');    # replaced later

    # shameless cut'n'paste from B::Deparse
    my ( $warn_sv, $isint );
    my $warnings   = $op->warnings;
    my $is_special = ref($warnings) eq 'B::SPECIAL';
    my $warnsvcast = "(STRLEN*)";
    if ($is_special) {
        $warn_sv = 'pWARN_STD';
        $warn_sv = 'pWARN_ALL' if $$warnings == 4;     # use warnings 'all';
        $warn_sv = 'pWARN_NONE' if $$warnings == 5;    # use warnings 'all';
    }
    else {
        # LEXWARN_on: Original $warnings->save from 5.8.9 was wrong,
        # DUP_WARNINGS copied length PVX bytes.
        my $warn = bless $warnings, "B::LEXWARN";

        # TODO: isint here misses already seen lexwarn symbols
        ( $warn_sv, $isint ) = $warn->save;

        # XXX No idea how a &sv_list[] came up here, a re-used object. Anyway.
        $warn_sv = substr( $warn_sv, 1 ) if substr( $warn_sv, 0, 3 ) eq '&sv';
        $warn_sv = $warnsvcast . '&' . $warn_sv;

        #push @B::C::static_free, sprintf("cop_list[%d]", $ix);
    }

    my $dynamic_copwarn = !$is_special ? 1 : 0;

    # Trim the .pl extension, to print the executable name only.
    my $file = $op->file;

    # cop_label now in hints_hash (Change #33656)
    my $add_label = $op->label ? 1 : 0;

    copsect()->debug( $op->name, $op );

    my $i = 0;
    if ( $op->hints_hash ) {
        my $hints = $op->hints_hash;

        if ( $hints && $$hints ) {
            if ( exists $cophhtable{$$hints} ) {
                my $cophh = $cophhtable{$$hints};
                init()->sadd( "CopHINTHASH_set(&cop_list[%d], %s);", $ix, $cophh );
            }
            else {
                my $hint_hv = $hints->HASH if ref $hints eq 'B::RHE';
                my $cophh = sprintf( "cophh%d", scalar keys %cophhtable );
                $cophhtable{$$hints} = $cophh;
                decl()->sadd( "Static COPHH *%s;", $cophh );
                foreach my $k ( sort keys %$hint_hv ) {
                    my ( $ck, $kl, $utf8 ) = strlen_flags($k);
                    my $v = $hint_hv->{$k};
                    next if $k eq ':';    #skip label, see below
                    my $val = B::svref_2object( \$v )->save("\$^H{$k}");
                    if ($utf8) {
                        init()->sadd(
                            "%s = cophh_store_pvn(%s, %s, %d, 0, %s, COPHH_KEY_UTF8);",
                            $cophh, $i ? $cophh : 'NULL', $ck, $kl, $val
                        );
                    }
                    else {
                        init()->sadd(
                            "%s = cophh_store_pvs(%s, %s, %s, 0);",
                            $cophh, $i ? $cophh : 'NULL', $ck, $val
                        );
                    }
                    $i++;
                }
                init()->sadd( "CopHINTHASH_set(&cop_list[%d], %s);", $ix, $cophh );
            }
        }

    }

    if ($add_label) {

        # test 29 and 15,16,21. 44,45
        my $label = $op->label;
        my ( $cstring, $cur, $utf8 ) = strlen_flags($label);
        $utf8 = 'SVf_UTF8' if $cstring =~ qr{\\[0-9]};    # help a little utf8, maybe move it to strlen_flags
        init()->sadd(
            "Perl_cop_store_label(aTHX_ &cop_list[%d], %s, %u, %s);",
            $ix, $cstring, $cur, $utf8
        );
    }

    if ( !$is_special and !$isint ) {
        my $copw = $warn_sv;
        $copw =~ s/^\(STRLEN\*\)&//;

        # on cv_undef (scope exit, die, Attribute::Handlers, ...) CvROOT and all its kids are freed.
        # lexical cop_warnings need to be dynamic, but just the ptr to the static string.
        if ($copw) {
            my $dest = "cop_list[$ix].cop_warnings";

            # with DEBUGGING savepvn returns ptr + PERL_MEMORY_DEBUG_HEADER_SIZE
            # which is not the address which will be freed in S_cop_free.
            # Need to use old-style PerlMemShared_, see S_cop_free in op.c (#362)
            # lexwarn<n> might be also be STRLEN* 0
            init()->sadd( "%s = (STRLEN*)savesharedpvn((const char*)%s, sizeof(%s));", $dest, $copw, $copw );
        }
    }

    my $stash = savestashpv( $op->stashpv );
    init()->sadd( "CopSTASH_set(&cop_list[%d], %s);", $ix, $stash );

    if ($B::C::const_strings) {
        my $constpv = constpv($file);

        # define CopFILE_set(c,pv)     CopFILEGV_set((c), gv_fetchfile(pv))
        # cache gv_fetchfile
        if ( !$copgvtable{$constpv} ) {
            $copgvtable{$constpv} = B::GV::inc_index();
            init()->sadd( "dynamic_gv_list[%d] = gv_fetchfile(%s);", $copgvtable{$constpv}, $constpv );
        }
        init()->sadd(
            "CopFILEGV_set(&cop_list[%d], dynamic_gv_list[%d]); /* %s */",
            $ix, $copgvtable{$constpv}, cstring($file)
        );
    }
    else {
        init()->sadd( "CopFILE_set(&cop_list[%d], %s);", $ix, cstring($file) );
    }

    # our root: store all packages from this file
    if ( !$B::C::mainfile ) {
        $B::C::mainfile = $op->file if $op->stashpv eq 'main';
    }
    else {
        B::C::mark_package( $op->stashpv ) if $B::C::mainfile eq $op->file and $op->stashpv ne 'main';
    }

    # add the cop at the end
    copsect()->comment_common("?, line_t line, HV* stash, GV* filegv, U32 hints, U32 seq, STRLEN* warn_sv, COPHH* hints_hash");
    copsect()->supdate(
        $ix,
        "%s, %u, (HV*) %s, (GV*) %s, %u, %s, %s, NULL",
        $op->_save_common, $op->line,

        # we cannot store this static (attribute exit)
        "Nullhv",    # stash
        "Nullgv",    # filegv
        $op->hints, get_integer_value( $op->cop_seq ), !$dynamic_copwarn ? $warn_sv : 'NULL'
    );

    return savesym( $op, "(OP*)&cop_list[$ix]" );
}

1;

__END__

#  define CopSTASH(c)       ((c)->cop_stash)
#  define CopFILE_set(c,pv)  CopFILEGV_set((c), gv_fetchfile(pv))

 #define BASEOP              \
     OP*     op_next;        \
     OP*     _OP_SIBPARENT_FIELDNAME;\
     OP*     (*op_ppaddr)(pTHX); \
     PADOFFSET   op_targ;        \
     PERL_BITFIELD16 op_type:9;      \
     PERL_BITFIELD16 op_opt:1;       \
     PERL_BITFIELD16 op_slabbed:1;   \
     PERL_BITFIELD16 op_savefree:1;  \
     PERL_BITFIELD16 op_static:1;    \
     PERL_BITFIELD16 op_folded:1;    \
     PERL_BITFIELD16 op_moresib:1;       \
     PERL_BITFIELD16 op_spare:1;     \
     U8      op_flags;       \
     U8      op_private;
 #endif

 struct cop {
     BASEOP
     /* On LP64 putting this here takes advantage of the fact that BASEOP isn't
        an exact multiple of 8 bytes to save structure padding.  */
     line_t      cop_line;       /* line # of this command */
     /* label for this construct is now stored in cop_hints_hash */
     HV *    cop_stash;  /* package line was compiled in */
     GV *    cop_filegv; /* file the following line # is from */
 
     U32     cop_hints;  /* hints bits from pragmata */
     U32     cop_seq;    /* parse sequence number */
     /* Beware. mg.c and warnings.pl assume the type of this is STRLEN *:  */
     STRLEN *    cop_warnings;   /* lexical warnings bitmask */
     /* compile time state of %^H.  See the comment in op.c for how this is
        used to recreate a hash to return from caller.  */
     COPHH * cop_hints_hash;
 };
