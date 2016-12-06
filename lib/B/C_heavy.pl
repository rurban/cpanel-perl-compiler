#      C.pm
#
#      Copyright (c) 1996, 1997, 1998 Malcolm Beattie
#      Copyright (c) 2008, 2009, 2010, 2011 Reini Urban
#      Copyright (c) 2010 Nick Koston
#      Copyright (c) 2011, 2012, 2013, 2014, 2015 cPanel Inc
#
#      You may distribute under the terms of either the GNU General Public
#      License or the Artistic License, as specified in the README file.
#

package B::C;
use strict;

# From C.pm
our %Config;
our ( $VERSION, $caller, $nullop_count, $unresolved_count, $gv_index, $settings );
our ( @ISA, @EXPORT_OK );
our $const_strings = 1;    # TODO: This var needs to go away.

BEGIN {
    use B::C::Flags ();
    *Config = \%B::C::Flags::Config;
}

use B::Flags;
use B::C::Config;          # import everything
use B::C::Debug ();        # used for setting debug levels from cmdline

use B::C::File qw( init2 init0 init decl free
  heksect binopsect condopsect copsect padopsect listopsect logopsect
  opsect pmopsect pvopsect svopsect unopsect svsect xpvsect xpvavsect xpvhvsect xpvcvsect xpvivsect xpvuvsect
  xpvnvsect xpvmgsect xpvlvsect xrvsect xpvbmsect xpviosect padlistsect loopsect sharedhe
);
use B::C::Helpers qw/set_curcv is_using_mro/;
use B::C::Helpers::Symtable qw(objsym savesym);

use Exporter ();
use Errno    ();           #needed since 5.14
our %Regexp;

# Caller was populated in C.pm
BEGIN {
    if ( $caller eq 'O' or $caller eq 'Od' ) {
        require XSLoader;
        no warnings;
        XSLoader::load('B::C');
    }
}

# for 5.6.[01] better use the native B::C
# but 5.6.2 works fine
use B qw(minus_c sv_undef walkoptree walkoptree_slow main_root main_start peekop
  class cchar svref_2object compile_stats comppadlist hash
  init_av end_av opnumber cstring
  HEf_SVKEY SVf_POK SVf_ROK SVf_IOK SVf_NOK SVf_IVisUV SVf_READONLY);

BEGIN {
    @B::NV::ISA = 'B::IV';    # add IVX to nv. This fixes test 23 for Perl 5.8
    B->import(qw(regex_padav SVp_NOK SVp_IOK CVf_CONST CVf_ANON SVt_PVGV));
}

use FileHandle;

use B::FAKEOP  ();
use B::STASHGV ();

use B::C::Optimizer::DynaLoader     ();
use B::C::Optimizer::UnusedPackages ();
use B::C::OverLoad                  ();
use B::C::Packages qw/is_package_used get_all_packages_used/;
use B::C::Save qw(constpv savepv savestashpv);
use B::C::Save::Signals ();

# FIXME: this part can now be dynamic
# exclude all not B::C:: prefixed subs
# used in CV
our %all_bc_deps;

BEGIN {
    # track all internally used packages. all other may not be deleted automatically
    # - hidden methods
    # uses now @B::C::Flags::deps
    %all_bc_deps = map { $_ => 1 } @B::C::Flags::deps;
}

our ( $package_pv,     @package_pv );    # global stash for methods since 5.13
our ( %xsub,           %init2_remap );
our ( %dumped_package, %isa_cache );

# fixme move to config
our ( $use_xsloader, $devel_peek_needed );

# options and optimizations shared with B::CC
our ( %savINC, %curINC, $mainfile );

our @xpvav_sizes;
our $in_endav;
my %static_core_pkg;

sub start_heavy {
    my $settings = $B::C::settings;

    $settings->{'output_file'} or die("Please supply a -o option to B::C");
    B::C::File::new( $settings->{'output_file'} );    # Singleton.
    B::C::Packages::new();                            # Singleton.

    B::C::Debug::setup_debug( $settings->{'debug_options'}, $settings->{'enable_verbose'} );

    B::C::Optimizer::UnusedPackages::stash_fixup();

    save_main();

    return;
}

# used by B::OBJECT
sub add_to_isa_cache {
    my ( $k, $v ) = @_;
    die unless defined $k;

    $isa_cache{$k} = $v;
    return;
}

sub add_to_currINC {
    my ( $k, $v ) = @_;
    die unless defined $k;

    $curINC{$k} = $v;
    return;
}

# This the Carp free workaround for DynaLoader::bootstrap
BEGIN {
    # Scoped no warnings without loading the module.
    local $^W;
    BEGIN { ${^WARNING_BITS} = 0; }
    *DynaLoader::croak = sub { die @_ }
}

sub walk_and_save_optree {
    my ( $name, $root, $start ) = @_;
    if ($root) {

        # B.xs: walkoptree does more, reifying refs. rebless or recreating it.
        verbose() ? walkoptree_slow( $root, "save" ) : walkoptree( $root, "save" );
    }
    return objsym($start);
}

my $saveoptree_callback;
BEGIN { $saveoptree_callback = \&walk_and_save_optree }
sub set_callback { $saveoptree_callback = shift }
sub saveoptree { &$saveoptree_callback(@_) }

# Look this up here so we can do just a number compare
# rather than looking up the name of every BASEOP in B::OP
# maybe use contant
our ( $OP_THREADSV, $OP_DBMOPEN, $OP_FORMLINE, $OP_UCFIRST );

BEGIN {
    $OP_THREADSV = opnumber('threadsv');
    $OP_DBMOPEN  = opnumber('dbmopen');
    $OP_FORMLINE = opnumber('formline');
    $OP_UCFIRST  = opnumber('ucfirst');
}

# 1. called from method_named, so hashp should be defined
# 2. called from svop before method_named to cache the $package_pv
sub svop_or_padop_pv {
    my $op = shift;
    my $sv;
    if ( !$op->can("sv") ) {
        if ( $op->can('name') and $op->name eq 'padsv' ) {
            my @c   = comppadlist->ARRAY;
            my @pad = $c[1]->ARRAY;
            return $pad[ $op->targ ]->PV if $pad[ $op->targ ] and $pad[ $op->targ ]->can("PV");

            # This might fail with B::NULL (optimized ex-const pv) entries in the pad.
        }

        # $op->can('pmreplroot') fails for 5.14
        if ( ref($op) eq 'B::PMOP' and $op->pmreplroot->can("sv") ) {
            $sv = $op->pmreplroot->sv;
        }
        else {
            return $package_pv unless $op->flags & 4;

            # op->first is disallowed for !KIDS and OPpCONST_BARE
            return $package_pv if $op->name eq 'const' and $op->flags & 64;
            return $package_pv unless $op->first->can("sv");
            $sv = $op->first->sv;
        }
    }
    else {
        $sv = $op->sv;
    }

    # XXX see SvSHARED_HEK_FROM_PV for the stash in S_method_common pp_hot.c
    # In this hash the CV is stored directly
    if ( $sv and $$sv ) {

        return $sv->PV if $sv->can("PV");
        if ( ref($sv) eq "B::SPECIAL" ) {    # DateTime::TimeZone
                                             # XXX null -> method_named
            debug( gv => "NYI S_method_common op->sv==B::SPECIAL, keep $package_pv" );
            return $package_pv;
        }
        if ( $sv->FLAGS & SVf_ROK ) {
            goto missing if $sv->isa("B::NULL");
            my $rv = $sv->RV;
            if ( $rv->isa("B::PVGV") ) {
                my $o = $rv->IO;
                return $o->STASH->NAME if $$o;
            }
            goto missing if $rv->isa("B::PVMG");
            return $rv->STASH->NAME;
        }
        else {
          missing:
            if ( $op->name ne 'method_named' ) {

                # Called from first const/padsv before method_named. no magic pv string, so a method arg.
                # The first const pv as method_named arg is always the $package_pv.
                return $package_pv;
            }
            elsif ( $sv->isa("B::IV") ) {
                WARN(
                    sprintf(
                        "Experimentally try method_cv(sv=$sv,$package_pv) flags=0x%x",
                        $sv->FLAGS
                    )
                );

                # QUESTION: really, how can we test it ?
                # XXX untested!
                return svref_2object( method_cv( $$sv, $package_pv ) );
            }
        }
    }
    else {
        my @c   = comppadlist->ARRAY;
        my @pad = $c[1]->ARRAY;
        return $pad[ $op->targ ]->PV if $pad[ $op->targ ] and $pad[ $op->targ ]->can("PV");
    }
}

sub IsCOW {
    return ( ref $_[0] && $_[0]->can('FLAGS') && $_[0]->FLAGS & 0x10000000 );    # since 5.22
}

sub IsCOW_hek {
    return IsCOW( $_[0] ) && !$_[0]->LEN;
}

# This pair is needed because B::FAKEOP::save doesn't scalar dereference
# $op->next and $op->sibling

# For 5.8:
# Current workaround/fix for op_free() trying to free statically
# defined OPs is to set op_seq = -1 and check for that in op_free().
# Instead of hardwiring -1 in place of $op->seq, we use $op_seq
# so that it can be changed back easily if necessary. In fact, to
# stop compilers from moaning about a U16 being initialised with an
# uncast -1 (the printf format is %d so we can't tweak it), we have
# to "know" that op_seq is a U16 and use 65535. Ugh.

# For 5.9 the hard coded text is the values for op_opt and op_static in each
# op.  The value of op_opt is irrelevant, and the value of op_static needs to
# be 1 to tell op_free that this is a statically defined op and that is
# shouldn't be freed.

# For 5.10 op_seq = -1 is gone, the temp. op_static also, but we
# have something better, we can set op_latefree to 1, which frees the children
# (e.g. savepvn), but not the static op.

# 5.8: U16 op_seq;
# 5.9.4: unsigned op_opt:1; unsigned op_static:1; unsigned op_spare:5;
# 5.10: unsigned op_opt:1; unsigned op_latefree:1; unsigned op_latefreed:1; unsigned op_attached:1; unsigned op_spare:3;
# 5.18: unsigned op_opt:1; unsigned op_slabbed:1; unsigned op_savefree:1; unsigned op_static:1; unsigned op_spare:3;
# 5.19: unsigned op_opt:1; unsigned op_slabbed:1; unsigned op_savefree:1; unsigned op_static:1; unsigned op_folded:1; unsigned op_spare:2;
# 5.21.2: unsigned op_opt:1; unsigned op_slabbed:1; unsigned op_savefree:1; unsigned op_static:1; unsigned op_folded:1; unsigned op_lastsib:1; unsigned op_spare:1;

# fixme only use opsect common
my $opsect_common;

BEGIN {
    # should use a static variable
    # only for $] < 5.021002
    $opsect_common = "next, sibling, ppaddr, " . ( MAD() ? "madprop, " : "" ) . "targ, type, " . "opt, slabbed, savefree, static, folded, moresib, spare" . ", flags, private";
}

sub opsect_common { return $opsect_common }

# save alternate ops if defined, and also add labels (needed for B::CC)
sub do_labels ($$@) {
    my $op    = shift;
    my $level = shift;

    for my $m (@_) {
        no strict 'refs';
        my $mo = $op->$m if $m;
        if ( $mo and $$mo ) {
            $mo->save($level)
              if $m ne 'first'
              or ( $op->flags & 4
                and !( $op->name eq 'const' and $op->flags & 64 ) );    #OPpCONST_BARE has no first
        }
    }
}

# method_named is in 5.6.1
sub method_named {
    my $name = shift;
    return unless $name;
    my $cop = shift;
    my $loc = $cop ? " at " . $cop->file . " line " . $cop->line : "";

    # Note: the pkg PV is unacessible(?) at PL_stack_base+TOPMARK+1.
    # But it is also at the const or padsv after the pushmark, before all args.
    # See L<perloptree/"Call a method">
    # We check it in op->_save_common
    if ( ref($name) eq 'B::CV' ) {
        WARN $name;
        return $name;
    }
    my $method;
    for ( $package_pv, @package_pv, 'main' ) {
        no strict 'refs';
        next unless defined $_;
        $method = $_ . '::' . $name;
        if ( defined(&$method) ) {
            last;
        }
        else {
            if ( my $parent = try_isa( $_, $name ) ) {
                last;
            }
            debug( cv => "no definition for method_name \"$method\"" );
        }
    }

    $method = $name unless $method;
    if ( exists &$method ) {    # Do not try to save non-existing methods
        debug( cv => "save method_name \"$method\"$loc" );
        return svref_2object( \&{$method} );
    }
    else {
        return 0;
    }
}

# scalar: pv. list: (stash,pv,sv)
# pads are not named, but may be typed
sub padop_name {
    my $op = shift;
    my $cv = shift;
    if (
        $op->can('name')
        and (  $op->name eq 'padsv'
            or $op->name eq 'method_named'
            or ref($op) eq 'B::SVOP' )
      )    #threaded
    {
        return () if $cv and ref( $cv->PADLIST ) eq 'B::SPECIAL';
        my @c     = ( $cv and ref($cv) eq 'B::CV' and ref( $cv->PADLIST ) ne 'B::NULL' ) ? $cv->PADLIST->ARRAY : comppadlist->ARRAY;
        my @types = $c[0]->ARRAY;
        my @pad   = $c[1]->ARRAY;
        my $ix    = $op->can('padix') ? $op->padix : $op->targ;
        my $sv    = $pad[$ix];
        my $t     = $types[$ix];
        if ( defined($t) and ref($t) ne 'B::SPECIAL' ) {
            my $pv = $sv->can("PV") ? $sv->PV : ( $t->can('PVX') ? $t->PVX : '' );
            return $pv;
        }
        elsif ($sv) {
            my $pv = $sv->PV if $sv->can("PV");
            return $pv;
        }
    }
}

sub svop_name {
    my $op = shift;
    my $cv = shift;
    my $sv;
    if ( $op->can('name') and $op->name eq 'padsv' ) {
        return padop_name( $op, $cv );
    }
    else {
        if ( !$op->can("sv") ) {
            if ( ref($op) eq 'B::PMOP' and $op->pmreplroot->can("sv") ) {
                $sv = $op->pmreplroot->sv;
            }
            else {
                $sv = $op->first->sv
                  unless $op->flags & 4
                  or ( $op->name eq 'const' and $op->flags & 34 )
                  or $op->first->can("sv");
            }
        }
        else {
            $sv = $op->sv;
        }
        if ( $sv and $$sv ) {
            if ( $sv->FLAGS & SVf_ROK ) {
                return '' if $sv->isa("B::NULL");
                my $rv = $sv->RV;
                if ( $rv->isa("B::PVGV") ) {
                    my $o = $rv->IO;
                    return $o->STASH->NAME if $$o;
                }
                return '' if $rv->isa("B::PVMG");
                return $rv->STASH->NAME;
            }
            else {
                if ( $op->name eq 'gvsv' or $op->name eq 'gv' ) {
                    return $sv->STASH->NAME . '::' . $sv->NAME;
                }

                return
                    $sv->can('STASH') ? $sv->STASH->NAME
                  : $sv->can('NAME')  ? $sv->NAME
                  :                     $sv->PV;
            }
        }
    }
}

# return the next COP for file and line info
sub nextcop {
    my $op = shift;
    while ( $op and ref($op) ne 'B::COP' and ref($op) ne 'B::NULL' ) { $op = $op->next; }
    return ( $op and ref($op) eq 'B::COP' ) ? $op : undef;
}

sub get_isa ($) {
    no strict 'refs';

    my $name = shift;
    if ( is_using_mro() ) {    # mro.xs loaded. c3 or dfs
        return @{ mro::get_linear_isa($name) };
    }

    # dfs only, without loading mro
    return @{ B::C::get_linear_isa($name) };
}

# try_isa($pkg,$name) returns the found $pkg for the method $pkg::$name
# If a method can be called (via UNIVERSAL::can) search the ISA's. No AUTOLOAD needed.
# XXX issue 64, empty @ISA if a package has no subs. in Bytecode ok
sub try_isa {
    my ( $cvstashname, $cvname ) = @_;
    return 0 unless defined $cvstashname;
    if ( my $found = $isa_cache{"$cvstashname\::$cvname"} ) {
        return $found;
    }
    no strict 'refs';

    # XXX theoretically a valid shortcut. In reality it fails when $cvstashname is not loaded.
    # return 0 unless $cvstashname->can($cvname);
    my @isa = get_isa($cvstashname);
    debug(
        cv => "No definition for sub %s::%s. Try \@%s::ISA=(%s)",
        $cvstashname, $cvname, $cvstashname, join( ",", @isa )
    );
    for (@isa) {    # global @ISA or in pad
        next if $_ eq $cvstashname;
        debug( cv => "Try &%s::%s", $_, $cvname );
        if ( defined( &{ $_ . '::' . $cvname } ) ) {
            if ( exists( ${ $cvstashname . '::' }{ISA} ) ) {
                svref_2object( \@{ $cvstashname . '::ISA' } )->save("$cvstashname\::ISA");
            }
            $isa_cache{"$cvstashname\::$cvname"} = $_;
            return $_;
        }
        else {
            $isa_cache{"$_\::$cvname"} = 0;
            if ( get_isa($_) ) {
                my $parent = try_isa( $_, $cvname );
                if ($parent) {
                    $isa_cache{"$_\::$cvname"}           = $parent;
                    $isa_cache{"$cvstashname\::$cvname"} = $parent;
                    debug( gv => "Found &%s::%s", $parent, $cvname );
                    if ( exists( ${ $parent . '::' }{ISA} ) ) {
                        debug( pkg => "save \@$parent\::ISA" );
                        svref_2object( \@{ $parent . '::ISA' } )->save("$parent\::ISA");
                    }
                    if ( exists( ${ $_ . '::' }{ISA} ) ) {
                        debug( pkg => "save \@$_\::ISA\n" );
                        svref_2object( \@{ $_ . '::ISA' } )->save("$_\::ISA");
                    }
                    return $parent;
                }
            }
        }
    }
    return 0;    # not found
}

sub load_utf8_heavy {
    return if $savINC{"utf8_heavy.pl"};

    require 'utf8_heavy.pl';
    $curINC{'utf8_heavy.pl'} = $INC{'utf8_heavy.pl'};
    $savINC{"utf8_heavy.pl"} = 1;
    add_hashINC("utf8");

    # FIXME: we want to use add_hashINC for utf8_heavy, inc_packname should return an array
    # add_hashINC("utf8_heavy.pl");

    # In CORE utf8::SWASHNEW is demand-loaded from utf8 with Perl_load_module()
    # It adds about 1.6MB exe size 32-bit.
    svref_2object( \&{"utf8\::SWASHNEW"} )->save;

    return 1;
}

# If the sub or method is not found:
# 1. try @ISA and return.
# 2. try UNIVERSAL::method
# 3. try compile-time expansion of AUTOLOAD to get the goto &sub addresses
sub try_autoload {
    my ( $cvstashname, $cvname ) = @_;
    no strict 'refs';
    return unless defined $cvstashname && defined $cvname;
    return 1 if try_isa( $cvstashname, $cvname );
    $cvname = '' unless defined $cvname;
    no strict 'refs';
    if ( defined( *{ 'UNIVERSAL::' . $cvname }{CODE} ) ) {
        debug( cv => "Found UNIVERSAL::$cvname" );
        return svref_2object( \&{ 'UNIVERSAL::' . $cvname } );
    }
    my $fullname = $cvstashname . '::' . $cvname;
    debug(
        cv => "No definition for sub %s. Try %s::AUTOLOAD",
        $fullname, $cvstashname
    );

    # First some exceptions, fooled by goto
    if ( $fullname eq 'utf8::SWASHNEW' ) {

        # utf8_heavy was loaded so far, so defer to a demand-loading stub
        # always require utf8_heavy, do not care if it s already in
        my $stub = sub { require 'utf8_heavy.pl'; goto &utf8::SWASHNEW };

        return svref_2object($stub);
    }

    # Handle AutoLoader classes. Any more general AUTOLOAD
    # use should be handled by the class itself.
    my @isa = get_isa($cvstashname);
    if ( $cvstashname =~ /^POSIX|Storable|DynaLoader|Net::SSLeay|Class::MethodMaker$/
        or ( exists ${ $cvstashname . '::' }{AUTOLOAD} and grep( $_ eq "AutoLoader", @isa ) ) ) {

        # Tweaked version of AutoLoader::AUTOLOAD
        my $dir = $cvstashname;
        $dir =~ s(::)(/)g;
        debug( cv => "require \"auto/$dir/$cvname.al\"" );
        eval { local $SIG{__DIE__}; require "auto/$dir/$cvname.al" unless $INC{"auto/$dir/$cvname.al"} };
        unless ($@) {
            verbose("Forced load of \"auto/$dir/$cvname.al\"");
            return svref_2object( \&$fullname )
              if defined &$fullname;
        }
    }

    # XXX TODO Check Selfloader (test 31?)
    svref_2object( \*{ $cvstashname . '::AUTOLOAD' } )->save
      if $cvstashname and exists ${ $cvstashname . '::' }{AUTOLOAD};
    svref_2object( \*{ $cvstashname . '::CLONE' } )->save
      if $cvstashname and exists ${ $cvstashname . '::' }{CLONE};
}

my @_v;

BEGIN {
    @_v = Internals::V();
}
sub __ANON__::_V { @_v }

sub save_object {
    foreach my $sv (@_) {
        svref_2object($sv)->save;
    }
}

# Fixes bug #307: use foreach, not each
# each is not safe to use (at all). walksymtable is called recursively which might add
# symbols to the stash, which might cause re-ordered rehashes, which will fool the hash
# iterator, leading to missing symbols in the binary.
# Old perl5 bug: The iterator should really be stored in the op, not the hash.
sub walksymtable {
    my ( $symref, $method, $recurse, $prefix ) = @_;
    my ( $sym, $ref, $fullname );
    $prefix = '' unless defined $prefix;

    # If load_utf8_heavy doesn't happen before we walk utf8:: (when utf8_heavy has already been called) then the stored CV for utf8::SWASHNEW could be wrong.
    load_utf8_heavy() if ( $prefix eq 'utf8::' && defined $symref->{'SWASHNEW'} );

    my @list = sort {

        # we want these symbols to be saved last to avoid incomplete saves
        # +/- reverse is to defer + - to fix Tie::Hash::NamedCapturespecial cases. GH #247
        # _loose_name redefined from utf8_heavy.pl
        # re can be loaded by utf8_heavy
        foreach my $v (qw{- + re:: utf8:: bytes::}) {
            $a eq $v and return 1;
            $b eq $v and return -1;
        }

        # reverse order for now to preserve original behavior before improved patch
        $b cmp $a
    } keys %$symref;

    # reverse is to defer + - to fix Tie::Hash::NamedCapturespecial cases. GH #247
    foreach my $sym (@list) {
        no strict 'refs';
        $ref      = $symref->{$sym};
        $fullname = "*main::" . $prefix . $sym;
        if ( $sym =~ /::$/ ) {
            $sym = $prefix . $sym;
            if ( svref_2object( \*$sym )->NAME ne "main::" && $sym ne "<none>::" && &$recurse($sym) ) {
                walksymtable( \%$fullname, $method, $recurse, $sym );
            }
        }
        else {
            svref_2object( \*$fullname )->$method();
        }
    }
}

sub walk_syms {
    my $package = shift;
    no strict 'refs';
    return if $dumped_package{$package};
    debug( pkg => "walk_syms $package" ) if verbose();
    $dumped_package{$package} = 1;
    walksymtable( \%{ $package . '::' }, "savecv", sub { 1 }, $package . '::' );
}

# simplified walk_syms
# needed to populate @B::C::Flags::deps from Makefile.PL from within this %INC context
sub walk_stashes {
    my ( $symref, $prefix, $dependencies ) = @_;
    no strict 'refs';
    $prefix = '' unless defined $prefix;
    foreach my $sym ( sort keys %$symref ) {
        if ( $sym =~ /::$/ ) {
            $sym = $prefix . $sym;
            $dependencies->{ substr( $sym, 0, -2 ) }++;
            if ( $sym ne "main::" && $sym ne "<none>::" ) {
                walk_stashes( \%$sym, $sym, $dependencies );
            }
        }
    }
}

# Used by Makefile.PL to autogenerate %INC deps.
# QUESTION: why Moose and IO::Socket::SSL listed here
# QUESTION: can we skip B::C::* here
sub collect_deps {
    my %deps;
    walk_stashes( \%main::, undef, \%deps );
    print join " ", ( sort keys %deps );
}

# XS in CORE which do not need to be bootstrapped extra.
# There are some specials like mro,re,UNIVERSAL.
sub in_static_core {
    my ( $stashname, $cvname ) = @_;
    if ( $stashname eq 'UNIVERSAL' ) {
        return $cvname =~ /^(isa|can|DOES|VERSION)$/;
    }
    %static_core_pkg = map { $_ => 1 } static_core_packages()
      unless %static_core_pkg;
    return 1 if $static_core_pkg{$stashname};
    if ( $stashname eq 'mro' ) {
        return $cvname eq 'method_changed_in';
    }
    if ( $stashname eq 're' ) {
        return $cvname =~ /^(is_regexp|regname|regnames|regnames_count|regexp_pattern)$/;
    }
    if ( $stashname eq 'PerlIO' ) {
        return $cvname eq 'get_layers';
    }
    if ( $stashname eq 'PerlIO::Layer' ) {
        return $cvname =~ /^(find|NoWarnings)$/;
    }
    return 0;
}

# XS modules in CORE. Reserved namespaces.
# Note: mro,re,UNIVERSAL have both, static core and dynamic/static XS
# version has an external ::vxs
sub static_core_packages {
    my @pkg = qw(version Internals utf8 UNIVERSAL);

    push @pkg, split( / /, $Config{static_ext} );
    return @pkg;
}

# Do not delete/ignore packages which were brought in from the script,
# i.e. not defined in B::C or O. Just to be on the safe side.
sub can_delete {
    my $pkg = shift;
    if ( exists $all_bc_deps{$pkg} ) { return 1 }
    return undef;
}

sub inc_packname {
    my $package = shift;

    # See below at the reverse packname_inc: utf8 => utf8.pm + utf8_heavy.pl
    $package =~ s/\:\:/\//g;
    $package .= '.pm';
    return $package;
}

sub packname_inc {
    my $package = shift;
    $package =~ s/\//::/g;
    if ( $package =~ /^(Config_git\.pl|Config_heavy.pl)$/ ) {
        return 'Config';
    }
    if ( $package eq 'utf8_heavy.pl' ) {
        return 'utf8';
    }
    $package =~ s/\.p[lm]$//;
    return $package;
}

sub delete_unsaved_hashINC {
    my $package = shift;
    my $incpack = inc_packname($package);

    # Not already saved package, so it is not loaded again at run-time.
    return if $dumped_package{$package};

    # Never delete external packages, but this check is done before
    return
          if $package =~ /^DynaLoader|XSLoader$/
      and defined $use_xsloader
      and $use_xsloader == 0;

    if ( $curINC{$incpack} ) {

        #debug( pkg => "Deleting $package from \%INC" );
        $savINC{$incpack} = $curINC{$incpack} if !$savINC{$incpack};
        $curINC{$incpack} = undef;
        delete $curINC{$incpack};
    }
}

sub add_hashINC {
    my $package = shift;
    my $incpack = inc_packname($package);

    unless ( $curINC{$incpack} ) {
        if ( $savINC{$incpack} ) {
            debug( pkg => "Adding $package to \%INC (again)" );
            $curINC{$incpack} = $savINC{$incpack};

            # need to check xsub
            $use_xsloader = 1 if $package =~ /^DynaLoader|XSLoader$/;
        }
        else {
            debug( pkg => "Adding $package to \%INC" );
            for (@INC) {
                my $p = $_ . '/' . $incpack;
                if ( -e $p ) { $curINC{$incpack} = $p; last; }
            }
            $curINC{$incpack} = $incpack unless $curINC{$incpack};
        }
    }
}

sub walkpackages {
    my ( $symref, $recurse, $prefix ) = @_;
    no strict 'vars';
    $prefix = '' unless defined $prefix;

    # check if already deleted - failed since 5.15.2
    return if $savINC{ inc_packname( substr( $prefix, 0, -2 ) ) };
    for my $sym ( sort keys %$symref ) {
        my $ref = $symref->{$sym};
        next unless $ref;
        local (*glob);
        *glob = $ref;
        if ( $sym =~ /::$/ ) {
            $sym = $prefix . $sym;
            debug( walk => "Walkpackages $sym" ) if debug('pkg');

            # This walker skips main subs to avoid recursion into O compiler subs again
            # and main syms are already handled
            if ( $sym ne "main::" && $sym ne "<none>::" && &$recurse($sym) ) {
                walkpackages( \%glob, $recurse, $sym );
            }
        }
    }
}

sub inc_cleanup {
    my $rec_cnt = shift;

    # %INC sanity check issue 89:
    # omit unused, unsaved packages, so that at least run-time require will pull them in.

    my @deleted_inc;
    for my $package ( sort keys %INC ) {
        my $pkg = packname_inc($package);
        if ( $package =~ /^(Config_git\.pl|Config_heavy.pl)$/ and !$dumped_package{'Config'} ) {
            delete $curINC{$package};
        }
        elsif ( $package eq 'utf8_heavy.pl' and !is_package_used('utf8') ) {
            delete $curINC{$package};
            delete_unsaved_hashINC('utf8');
        }
    }

    # sync %curINC deletions back to %INC
    for my $p ( sort keys %INC ) {
        if ( !exists $curINC{$p} ) {
            delete $INC{$p};
            push @deleted_inc, $p;
        }
    }
    if ( debug('pkg') and verbose() ) {
        debug( pkg => "\%include_package: " . join( " ", get_all_packages_used() ) );
        debug( pkg => "\%dumped_package:  " . join( " ", grep { $dumped_package{$_} } sort keys %dumped_package ) );
    }

    # issue 340,350: do only on -fwalkall? do it in the main walker step
    # as in branch walkall-early?
    my $again = dump_rest();
    inc_cleanup( $rec_cnt++ ) if $again and $rec_cnt < 2;    # maximal 3 times

    # final cleanup
    for my $p ( sort keys %INC ) {
        my $pkg = packname_inc($p);
        delete_unsaved_hashINC($pkg) unless exists $dumped_package{$pkg};

        # sync %curINC deletions back to %INC
        if ( !exists $curINC{$p} and exists $INC{$p} ) {
            delete $INC{$p};
            push @deleted_inc, $p;
        }
    }

    if ( verbose() ) {
        debug( pkg => "Deleted from \%INC: " . join( " ", @deleted_inc ) ) if @deleted_inc;
        my @inc = grep !/auto\/.+\.(al|ix)$/, sort keys %INC;
        debug( pkg => "\%INC: " . join( " ", @inc ) );
    }
}

sub dump_rest {
    my $again;
    verbose("dump_rest");
    for my $p ( get_all_packages_used() ) {
        $p =~ s/^main:://;
        if (    is_package_used($p)
            and !exists $dumped_package{$p}
            and !$static_core_pkg{$p}
            and $p !~ /^(threads|main|__ANON__|PerlIO)$/ ) {
            if ( $p eq 'warnings::register' ) {
                delete_unsaved_hashINC('warnings::register');
                next;
            }
            $again++;
            debug( [qw/verbose pkg/], "$p marked but not saved, save now" );

            walk_syms($p);
        }
    }
    $again;
}

my @made_c3;

sub make_c3 {
    my $symbol = shift or die;

    return if ( grep { $_ eq $symbol } @made_c3 );
    push @made_c3, $symbol;

    return init2()->sadd( 'Perl_mro_set_mro(aTHX_ HvMROMETA(%s), newSVpvs("c3"));', $symbol );
}

# global state only, unneeded for modules
sub save_context {

    # forbid run-time extends of curpad syms, names and INC
    verbose("save context:");

    my $warner = $SIG{__WARN__};
    B::C::Save::Signals::save($warner);    # FIXME ? $warner seems useless arg to save_sig call
                                           # honour -w and %^H
    init()->add("/* honor -w */");
    init()->sadd( "PL_dowarn = ( %s ) ? G_WARN_ON : G_WARN_OFF;", $^W );
    if ( $^{TAINT} ) {
        init()->add(
            "/* honor -Tt */",
            "PL_tainting = TRUE;",

            # -T -1 false, -t 1 true
            "PL_taint_warn = " . ( $^{TAINT} < 0 ? "FALSE" : "TRUE" ) . ";"
        );
    }

    no strict 'refs';
    if ( defined( objsym( svref_2object( \*{'main::!'} ) ) ) ) {
        use strict 'refs';
        if ( !is_package_used('Errno') ) {
            init()->add("/* force saving of Errno */");
            svref_2object( \&{'Errno::bootstrap'} )->save;
        }    # else already included
    }
    else {
        use strict 'refs';
        delete_unsaved_hashINC('Errno');
    }

    my ( $curpad_nam, $curpad_sym );
    {
        # Record comppad sv's names, may not be static
        local $B::C::const_strings = 0;
        init()->add("/* curpad names */");
        verbose("curpad names:");
        $curpad_nam = ( comppadlist->ARRAY )[0]->save('curpad_name');
        verbose("curpad syms:");
        init()->add("/* curpad syms */");
        $curpad_sym = ( comppadlist->ARRAY )[1]->save('curpad_syms');
    }
    my ( $inc_hv, $inc_av );
    {
        local $B::C::const_strings = 1;
        verbose("\%INC and \@INC:");
        init()->add('/* %INC */');
        inc_cleanup(0);
        my %backup_INC = %INC;    # backup INC
        %INC = %{ $settings->{'starting_INC'} };    # use frozen INC
        my $inc_gv = svref_2object( \*main::INC );
        $inc_hv = $inc_gv->HV->save('main::INC');
        init()->add('/* @INC */');
        $inc_av = $inc_gv->AV->save('main::INC');
        %INC    = %backup_INC;                      # restore
    }

    # TODO: Not clear if this is needed any more given
    ## ensure all included @ISA's are stored (#308), and also assign c3 (#325)
    #my @saved_isa;
    #for my $p ( get_all_packages_used() ) {
    #    no strict 'refs';
    #    if ( exists( ${ $p . '::' }{ISA} ) and ${ $p . '::' }{ISA} ) {
    #        push @saved_isa, $p;
    #        svref_2object( \@{ $p . '::ISA' } )->save( $p . '::ISA' );
    #        if ( is_using_mro() && mro::get_mro($p) eq 'c3' ) {
    #            make_c3($p);
    #        }
    #    }
    #}
    #debug( [qw/verbose pkg/], "Saved \@ISA for: " . join( " ", @saved_isa ) ) if @saved_isa;
    init()->add(
        "GvHV(PL_incgv) = $inc_hv;",
        "GvAV(PL_incgv) = $inc_av;",
        "PL_curpad = AvARRAY($curpad_sym);",
        "PL_comppad = $curpad_sym;",      # fixed "panic: illegal pad"
        "PL_stack_sp = PL_stack_base;"    # reset stack (was 1++)
    );

    init()->add(
        "PadlistNAMES(CvPADLIST(PL_main_cv)) = PL_comppad_name = $curpad_nam; /* namepad */",
        "PadlistARRAY(CvPADLIST(PL_main_cv))[1] = (PAD*)$curpad_sym; /* curpad */"
    );
}

my $pl_defstash;

sub save_main {
    verbose("Starting compile");

    verbose("Backing up all pre-existing stashes.");
    $pl_defstash = svref_2object( \%main:: )->save('%main::');

    verbose("Walking tree");
    %Exporter::Cache = ();    # avoid B::C and B symbols being stored
                              #_delete_macros_vendor_undefined();
                              #set_curcv(B::main_cv);

    if ( debug('walk') ) {
        verbose("Enabling B::debug / B::walkoptree_debug");
        B->debug(1);

        # this is enabling walkoptree_debug
        # which is useful when using walkoptree (not the slow version)
    }

    verbose()
      ? walkoptree_slow( main_root, "save" )
      : walkoptree( main_root, "save" );
    save_main_rest();
}

sub _delete_macros_vendor_undefined {
    foreach my $class (qw(POSIX IO Fcntl Socket Exporter Errno)) {
        no strict 'refs';
        no strict 'subs';
        no warnings 'uninitialized';
        my $symtab = $class . '::';
        for my $symbol ( sort keys %$symtab ) {
            next if $symbol !~ m{^[0-9A-Z_]+$} || $symbol =~ m{(?:^ISA$|^EXPORT|^DESTROY|^TIE|^VERSION|^AUTOLOAD|^BEGIN|^INIT|^__|^DELETE|^CLEAR|^STORE|^NEXTKEY|^FIRSTKEY|^FETCH|^EXISTS)};
            next if ref $symtab->{$symbol};
            local $@;
            my $code = "$class\:\:$symbol();";
            eval $code;
            if ( $@ =~ m{vendor has not defined} ) {
                delete $symtab->{$symbol};
                next;
            }
        }
    }
    return 1;
}

sub force_saving_xsloader {

    init()->add("/* custom XSLoader::load_file */");

    # does this really save the whole packages?
    $dumped_package{DynaLoader} = 1;
    svref_2object( \&XSLoader::load_file )->save;
    svref_2object( \&DynaLoader::dl_load_flags )->save;    # not saved as XSUB constant?

    add_hashINC("DynaLoader");
    $use_xsloader = 0;                                     # do not load again
}

sub save_main_rest {
    debug( [qw/verbose cv/], "done main optree, walking symtable for extras" );
    init()->add("");
    init()->add("/* done main optree, extra subs which might be unused */");

    init()->add("/* done extras */");

    # startpoints: XXX TODO push BEGIN/END blocks to modules code.
    debug( av => "Writing init_av" );
    my $init_av = init_av->save('INIT');
    my $end_av;
    {
        # >=5.10 need to defer nullifying of all vars in END, not only new ones.
        local ($B::C::const_strings);
        $in_endav = 1;
        debug( 'av' => "Writing end_av" );
        init()->add("/* END block */");
        $end_av   = end_av->save('END');
        $in_endav = 0;
    }

    init()->add(
        "/* startpoints */",
        sprintf( "PL_main_root = s\\_%x;",  ${ main_root() } ),
        sprintf( "PL_main_start = s\\_%x;", ${ main_start() } ),
    );
    init()->add(
        index( $init_av, '(AV*)' ) >= 0
        ? "PL_initav = $init_av;"
        : "PL_initav = (AV*)$init_av;"
    );
    init()->add(
        index( $end_av, '(AV*)' ) >= 0
        ? "PL_endav = $end_av;"
        : "PL_endav = (AV*)$end_av;"
    );

    my %INC_BACKUP = %INC;
    save_context();

    # verbose("use_xsloader=$use_xsloader");
    # If XSLoader was forced later, e.g. in curpad, INIT or END block
    force_saving_xsloader() if $use_xsloader;

    return if $settings->{'check'};

    fixup_ppaddr();

    my $remap = 0;
    for my $pkg ( sort keys %init2_remap ) {
        if ( exists $xsub{$pkg} ) {    # check if not removed in between
            my ($stashfile) = $xsub{$pkg} =~ /^Dynamic-(.+)$/;

            # get so file from pm. Note: could switch prefix from vendor/site//
            $init2_remap{$pkg}{FILE} = dl_module_to_sofile( $pkg, $stashfile );
            $remap++;
        }
    }

    if ($remap) {

        # XXX now emit arch-specific dlsym code
        init2()->no_split;
        init2()->add("{");
        if ( HAVE_DLFCN_DLOPEN() ) {
            init2()->add("  #include <dlfcn.h>");
            init2()->add("  void *handle;");
        }
        else {
            init2()->add("  void *handle;");
            init2()->add(
                "  dTARG; dSP;",
                "  targ=sv_newmortal();"
            );
        }
        for my $pkg ( sort keys %init2_remap ) {
            if ( exists $xsub{$pkg} ) {
                if ( HAVE_DLFCN_DLOPEN() ) {
                    my $ldopt = 'RTLD_NOW|RTLD_NOLOAD';
                    $ldopt = 'RTLD_NOW' if $^O =~ /bsd/i;    # 351 (only on solaris and linux, not any bsd)
                    init2()->sadd( "\n  handle = dlopen(%s, %s);", cstring( $init2_remap{$pkg}{FILE} ), $ldopt );
                }
                else {
                    init2()->add(
                        "  PUSHMARK(SP);",
                        sprintf( "  XPUSHs(newSVpvs(%s));", cstring( $init2_remap{$pkg}{FILE} ) ),
                        "  PUTBACK;",
                        "  XS_DynaLoader_dl_load_file(aTHX_ NULL);",
                        "  SPAGAIN;",
                        "  handle = INT2PTR(void*,POPi);",
                        "  PUTBACK;",
                    );
                }
                for my $mg ( @{ $init2_remap{$pkg}{MG} } ) {
                    verbose("init2 remap xpvmg_list[$mg->{ID}].xiv_iv to dlsym of $pkg\: $mg->{NAME}");
                    if ( HAVE_DLFCN_DLOPEN() ) {
                        init2()->sadd( "  xpvmg_list[%d].xiv_iv = PTR2IV( dlsym(handle, %s) );", $mg->{ID}, cstring( $mg->{NAME} ) );
                    }
                    else {
                        init2()->add(
                            "  PUSHMARK(SP);",
                            "  XPUSHi(PTR2IV(handle));",
                            sprintf( "  XPUSHs(newSVpvs(%s));", cstring( $mg->{NAME} ) ),
                            "  PUTBACK;",
                            "  XS_DynaLoader_dl_load_file(aTHX_ NULL);",
                            "  SPAGAIN;",
                            sprintf( "  xpvmg_list[%d].xiv_iv = POPi;", $mg->{ID} ),
                            "  PUTBACK;",
                        );
                    }
                }
            }
        }
        init2()->add("}");
        init2()->split;
    }

    my %static_ext = map { ( $_ => 1 ) } grep { m/\S/ } split( /\s+/, $Config{static_ext} );
    my @stashxsubs = map { s/::/__/g; $_ } sort keys %static_ext;

    # Used to be in output_main_rest(). Seems to be trying to clean up xsub
    foreach my $stashname ( sort keys %xsub ) {
        my $incpack = $stashname;
        $incpack =~ s/\:\:/\//g;
        $incpack .= '.pm';
        unless ( exists $B::C::curINC{$incpack} ) {    # skip deleted packages
            debug( pkg => "skip xs_init for $stashname !\$INC{$incpack}" );
            delete $xsub{$stashname} unless $static_ext{$stashname};
        }

        # actually boot all non-b-c dependent modules here. we assume XSLoader (Moose, List::MoreUtils)
        if ( !exists( $xsub{$stashname} ) and is_package_used($stashname) ) {
            $xsub{$stashname} = 'Dynamic-' . $INC{$incpack};

            # Class::MOP without Moose: find Moose.pm
            $xsub{$stashname} = 'Dynamic-' . $B::C::savINC{$incpack} unless $INC{$incpack};
            if ( !$B::C::savINC{$incpack} ) {
                eval "require $stashname;";
                $xsub{$stashname} = 'Dynamic-' . $INC{$incpack};
            }
            verbose("Assuming xs loaded $stashname with $xsub{$stashname}");
        }
    }

    # Used to be buried in output_main_rest(); Seems to be more xsub cleanup.
    delete $xsub{'DynaLoader'};
    delete $xsub{'UNIVERSAL'};

    my $dynaloader_optimizer = B::C::Optimizer::DynaLoader->new( { 'xsub' => \%xsub, 'curINC' => \%curINC, 'output_file' => $settings->{'output_file'}, 'staticxs' => $settings->{staticxs} } );
    $dynaloader_optimizer->optimize();

    my $c_file_stash = build_template_stash( \%static_ext, \@stashxsubs, $dynaloader_optimizer );

    verbose("Writing output");
    %INC = %INC_BACKUP;    # Put back %INC now we've saved everything so Template can be loaded properly.
    B::C::File::write($c_file_stash);

    # Can use NyTProf with B::C
    if ( $INC{'Devel/NYTProf.pm'} ) {
        eval q/DB::finish_profile()/;
    }
}

sub build_template_stash {
    my ( $static_ext, $stashxsubs, $dynaloader_optimizer ) = @_;

    my $c_file_stash = {
        'verbose'               => verbose(),
        'debug'                 => B::C::Debug::save(),
        'PL_defstash'           => $pl_defstash,
        'creator'               => "created at " . scalar localtime() . " with B::C $VERSION for $^X",
        'DEBUG_LEAKING_SCALARS' => DEBUG_LEAKING_SCALARS(),
        'static_ext'            => $static_ext,
        'stashxsubs'            => $stashxsubs,
        'init_name'             => $settings->{'init_name'} || "perl_init",
        'gv_index'              => $gv_index,
        'init2_remap'           => \%init2_remap,
        'HAVE_DLFCN_DLOPEN'     => HAVE_DLFCN_DLOPEN(),
        'compile_stats'         => compile_stats(),
        'nullop_count'          => $nullop_count,
        'xsub'                  => \%xsub,
        'curINC'                => \%curINC,
        'staticxs'              => $settings->{'staticxs'},
        'all_eval_pvs'          => \@B::C::InitSection::all_eval_pvs,
        'TAINT'                 => ( ${^TAINT} ? 1 : 0 ),
        'devel_peek_needed'     => $devel_peek_needed,
        'optimizer'             => {
            'dynaloader' => $dynaloader_optimizer->stash(),
        }
    };
    chomp $c_file_stash->{'compile_stats'};    # Injects a new line when you call compile_stats()

    # main() .c generation needs a buncha globals to be determined so the stash can access them.
    # Some of the vars are only put in the stash if they meet certain coditions.

    $c_file_stash->{'global_vars'} = {
        'dollar_0'             => $0,
        'dollar_caret_A'       => $^A,
        'dollar_caret_H'       => $^H,
        'dollar_caret_X'       => cstring($^X),
        'dollar_caret_UNICODE' => ${^UNICODE},
        'dollar_comma'         => ${,},
        'dollar_backslash'     => ${\},
        'dollar_pipe'          => $|,
        'dollar_percent'       => $%,
    };

    $c_file_stash->{'global_vars'}->{'dollar_semicolon'} = cstring($;)  if $; ne "\34";     # $;
    $c_file_stash->{'global_vars'}->{'dollar_quote'}     = cstring($")  if $" ne " ";       # $"
    $c_file_stash->{'global_vars'}->{'dollar_slash'}     = cstring($/)  if $/ ne "\n";      # $/  - RS
    $c_file_stash->{'global_vars'}->{'dollar_caret_L'}   = cstring($^L) if $^L ne "\f";     # $^L - FORMFEED
    $c_file_stash->{'global_vars'}->{'dollar_colon'}     = cstring($:)  if $: ne " \n-";    # $:  - LINE_BREAK_CHARACTERS
    $c_file_stash->{'global_vars'}->{'dollar_minus'} = $- unless ( $- == 0 or $- == 60 );   # $-  - LINES_LEFT
    $c_file_stash->{'global_vars'}->{'dollar_equal'} = $= if $= != 60;                      # $=  - LINES_PER_PAGE

    # Need more than just the cstring.
    $c_file_stash->{'global_vars'}->{'dollar_caret'} = { 'str' => cstring($^), 'len' => length($^) } if $^ ne "STDOUT_TOP";
    $c_file_stash->{'global_vars'}->{'dollar_tilde'} = { 'str' => cstring($~), 'len' => length($~) } if $~ ne "STDOUT";

    $[ and die 'Since the variable is deprecated, B::C does not support setting $[ to anything other than 0';

    # PL_strtab's hash size
    $c_file_stash->{'PL_strtab_max'} = B::HV::get_max_hash_from_keys( sharedhe()->index() + 1, 511 ) + 1;

    return $c_file_stash;
}

# init op addrs must be the last action, otherwise
# some ops might not be initialized
# but it needs to happen before CALLREGCOMP, as a /i calls a compiled utf8::SWASHNEW
sub fixup_ppaddr {
    foreach my $op_section_name ( B::C::File::op_sections() ) {
        my $section = B::C::File::get_sect($op_section_name);
        my $num     = $section->index;
        next unless $num >= 0;
        init_op_addr( $section->name, $num + 1 );
    }
}

# needed for init2 remap and Dynamic annotation
sub dl_module_to_sofile {
    my $module     = shift or die "missing module name";
    my $modlibname = shift or die "missing module filepath";
    my @modparts = split( /::/, $module );
    my $modfname = $modparts[-1];
    my $modpname = join( '/', @modparts );
    my $c        = @modparts;
    $modlibname =~ s,[\\/][^\\/]+$,, while $c--;    # Q&D basename
    die "missing module filepath" unless $modlibname;
    my $sofile = "$modlibname/auto/$modpname/$modfname." . $Config{dlext};
    return $sofile;
}

# 5.15.3 workaround [perl #101336], without .bs support
# XSLoader::load_file($module, $modlibname, ...)
my $dlext;

BEGIN {
    $dlext = $Config{dlext};
    eval q|
sub XSLoader::load_file {
  #package DynaLoader;
  my $module = shift or die "missing module name";
  my $modlibname = shift or die "missing module filepath";
  print STDOUT "XSLoader::load_file(\"$module\", \"$modlibname\" @_)\n"
      if ${DynaLoader::dl_debug};

  push @_, $module;
  # works with static linking too
  my $boots = "$module\::bootstrap";
  goto &$boots if defined &$boots;

  my @modparts = split(/::/,$module); # crashes threaded, issue 100
  my $modfname = $modparts[-1];
  my $modpname = join('/',@modparts);
  my $c = @modparts;
  $modlibname =~ s,[\\/][^\\/]+$,, while $c--;    # Q&D basename
  die "missing module filepath" unless $modlibname;
  my $file = "$modlibname/auto/$modpname/$modfname."| . qq(."$dlext") . q|;

  # skip the .bs "bullshit" part, needed for some old solaris ages ago

  print STDOUT "goto DynaLoader::bootstrap_inherit\n"
      if ${DynaLoader::dl_debug} and not -f $file;
  goto \&DynaLoader::bootstrap_inherit if not -f $file;
  my $modxsname = $module;
  $modxsname =~ s/\W/_/g;
  my $bootname = "boot_".$modxsname;
  @DynaLoader::dl_require_symbols = ($bootname);

  my $boot_symbol_ref;
  if ($boot_symbol_ref = DynaLoader::dl_find_symbol(0, $bootname)) {
    print STDOUT "dl_find_symbol($bootname) ok => goto boot\n"
      if ${DynaLoader::dl_debug};
    goto boot; #extension library has already been loaded, e.g. darwin
  }
  # Many dynamic extension loading problems will appear to come from
  # this section of code: XYZ failed at line 123 of DynaLoader.pm.
  # Often these errors are actually occurring in the initialisation
  # C code of the extension XS file. Perl reports the error as being
  # in this perl code simply because this was the last perl code
  # it executed.

  my $libref = DynaLoader::dl_load_file($file, 0) or do {
    die("Can't load '$file' for module $module: " . DynaLoader::dl_error());
  };
  push(@DynaLoader::dl_librefs,$libref);  # record loaded object

  my @unresolved = DynaLoader::dl_undef_symbols();
  if (@unresolved) {
    die("Undefined symbols present after loading $file: @unresolved\n");
  }

  $boot_symbol_ref = DynaLoader::dl_find_symbol($libref, $bootname) or do {
    die("Can't find '$bootname' symbol in $file\n");
  };
  print STDOUT "dl_find_symbol($libref, $bootname) ok => goto boot\n"
    if ${DynaLoader::dl_debug};
  push(@DynaLoader::dl_modules, $module); # record loaded module

 boot:
  my $xs = DynaLoader::dl_install_xsub($boots, $boot_symbol_ref, $file);
  print STDOUT "dl_install_xsub($boots, $boot_symbol_ref, $file)\n"
    if ${DynaLoader::dl_debug};
  # See comment block above
  push(@DynaLoader::dl_shared_objects, $file); # record files loaded
  return &$xs(@_);
}
|;
}

sub init_op_addr {
    my ( $op_type, $num ) = @_;
    my $op_list = $op_type . "_list";

    init0()->add( split /\n/, <<_EOT3 );
{
    register int i;
    for( i = 0; i < ${num}; ++i ) {
        ${op_list}\[i].op_ppaddr = PL_ppaddr[PTR2IV(${op_list}\[i].op_ppaddr)];
    }
}
_EOT3

}

1;
