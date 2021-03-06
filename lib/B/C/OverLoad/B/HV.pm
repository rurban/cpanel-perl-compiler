package B::C::HV;

my $hv_index = 0;

sub get_index {
    return $hv_index;
}

sub inc_index {
    return ++$hv_index;
}

1;

package B::HV;

use strict;

use B qw/cstring SVf_READONLY SVf_PROTECT SVs_OBJECT SVf_OOK SVf_AMAGIC/;
use B::C::Config;
use B::C::File qw/init xpvhvsect svsect sharedhe decl init1 init2 init_stashes/;
use B::C::Helpers qw/read_utf8_string strlen_flags is_using_mro/;
use B::C::Helpers::Symtable qw/objsym savesym/;
use B::C::Save::Hek qw/save_shared_he/;

my ($swash_ToCf);

sub swash_ToCf_value {    # NO idea what it s ??
    return $swash_ToCf;
}

our %stash_cache;

sub do_save {
    my ( $hv, $fullname ) = @_;

    $fullname = '' unless $fullname;
    my $stash_name = $hv->NAME;
    my $magic;
    my $sym;

    my $sv_list_index = svsect()->add("FAKE_HV");
    $sym = savesym( $hv, "(HV*)&sv_list[$sv_list_index]" );
    $stash_cache{$stash_name} = $sym if ($stash_name);

    # could also simply use: savesym( $hv, sprintf( "s\\_%x", $$hv ) );

    # reduce the content
    # remove values from contents we are not going to save
    my %contents = $hv->ARRAY;
    if (%contents) {
        local $B::C::const_strings = $B::C::const_strings;

        # Walk the values and save them into symbols
        foreach my $key ( sort keys %contents ) {

            # $stash_name means it is a stash.
            if ( $stash_name && !B::C::Optimizer::UnusedPackages::gv_was_in_original_program( $stash_name . '::' . $key ) ) {
                delete $contents{$key};
                next;
            }

            my $sv = $contents{$key};

            #if ( debug('hv') and ref($sv) eq 'B::RV' and defined objsym($sv) ) {
            #    WARN( "HV recursion? with $fullname\{$key\} -> %s\n", $sv->RV );
            #}

            #debug( hv => "saving HV [ $i / len=$length ]\$" . $fullname . '{' . $key . "} 0x%0x", $sv );
            $contents{$key} = $sv->save($key);    # Turn the hash value into a symbol

            delete $contents{$key} if !defined $contents{$key};
        }
    }

    # Ordinary HV or Stash
    # KEYS = 0, inc. dynamically below with hv_store

    my $hv_total_keys = scalar keys %contents;
    my $max           = get_max_hash_from_keys($hv_total_keys);
    xpvhvsect()->comment("HV* xmg_stash, union _xmgu mgu, STRLEN xhv_keys, STRLEN xhv_max");
    xpvhvsect()->sadd( "Nullhv, {0}, %d, %d", $hv_total_keys, $max );

    my $flags = $hv->FLAGS & ~SVf_READONLY & ~SVf_PROTECT;

    # replace the previously saved svsect with some accurate content
    svsect()->update(
        $sv_list_index,
        sprintf(
            "&xpvhv_list[%d], %Lu, 0x%x, {0}",
            xpvhvsect()->index, $hv->REFCNT, $flags
        )
    );

    my $init = $stash_name ? init_stashes() : init();
    {    # add hash content even if the hash is empty [ maybe only for %INC ??? ]
        $init->no_split;
        $init->sadd("/* STASH declaration for $stash_name */") if $stash_name;
        $init->sadd( qq[{\n] . q{HvSETUP(%s, %d);}, $sym, $max + 1 );

        foreach my $key ( sort keys %contents ) {

            # Insert each key into the hash.
            my $shared_he = save_shared_he($key);
            $init->sadd( q{HvAddEntry(%s, (SV*) %s, %s, %d);}, $sym, $contents{$key}, $shared_he, $max );

            #debug( hv => q{ HV key "%s" = %s}, $key, $value );
        }

        # save the iterator in hv_aux (and malloc it)
        $init->sadd( "HvRITER_set(%s, %d);", $sym, -1 );    # saved $hv->RITER

        $init->add("}");
        $init->split;
    }

    $magic = $hv->save_magic($fullname);
    $init->add("SvREADONLY_on($sym);") if $hv->FLAGS & SVf_READONLY;
    if ( $magic =~ /c/ ) {

        # defer AMT magic of XS loaded stashes
        my ( $cname, $len, $utf8 ) = strlen_flags($stash_name);

        # TODO NEED A BETTER FIX FOR THIS
        #init2()->add(qq[$sym = gv_stashpvn($cname, $len, GV_ADDWARN|GV_ADDMULTI|$utf8);]);
    }

    if ( $stash_name and is_using_mro() and mro::get_mro($stash_name) eq 'c3' ) {
        B::C::make_c3($stash_name);
    }

    $hv->do_special_stash_stuff( $stash_name, $sym );

    return $sym;
}

sub get_max_hash_from_keys {
    my ( $keys, $default ) = @_;
    $default ||= 7;

    return $default if !$keys or $keys <= $default;    # default hash max value

    return 2**( int( log($keys) / log(2) ) + 1 ) - 1;
}

sub do_special_stash_stuff {
    my ( $hv, $stash_name, $sym ) = @_;

    return unless $stash_name;

    # SVf_AMAGIC is set on almost every stash until it is
    # used.  This forces a transversal of the stash to remove
    # the flag if its not actually needed.
    # fix overload stringify
    # Gv_AMG: potentially removes the AMG flag
    if ( $hv->FLAGS & SVf_AMAGIC and length($stash_name) and $hv->Gv_AMG ) {
        init2()->sadd( "mro_isa_changed_in(%s);  /* %s */", $sym, $stash_name );
    }

    # Add aliases if namecount > 1 (GH #331)
    # There was no B API for the count or multiple enames, so I added one.
    my @enames = $hv->ENAMES;
    if ( @enames > 1 ) {
        debug( hv => "Saving for $stash_name multiple enames: ", join( " ", @enames ) );
        my $stash_name_count = $hv->name_count;

        # If the stash name is empty xhv_name_count is negative, and names[0] should
        # be already set. but we rather write it.
        init_stashes()->no_split;

        # unshift @enames, $stash_name if $stash_name_count < 0; # stashpv has already set names[0]
        init_stashes()->add(
            "{",
            "  struct xpvhv_aux *aux = HvAUX($sym);",
            sprintf( "  Newx(aux->xhv_name_u.xhvnameu_names, %d, HEK*);", $stash_name_count ),
            sprintf( "  aux->xhv_name_count = %d;",                       $stash_name_count )
        );
        my $i = 0;
        foreach my $ename (@enames) {
            init_stashes()->sadd( "  aux->xhv_name_u.xhvnameu_names[%u] = (HEK*) %s;", $i++, save_shared_he($ename) );
        }
        init_stashes()->add("}");
        init_stashes()->split;
    }
    else {
        init_stashes()->sadd( "HvAUX(%s)->xhv_name_u.xhvnameu_name = (HEK*) %s;", $sym, save_shared_he($stash_name) );
    }

    # issue 79, test 46: save stashes to check for packages.
    # and via B::STASHGV we only save stashes for stashes.
    # For efficiency we skip most stash symbols unless -fstash.
    # However it should be now safe to save all stash symbols.
    # $fullname !~ /::$/ or

    my $magic = $hv->save_magic( '%' . $stash_name . '::' );    #symtab magic set in PMOP #188 (#267)
    if ( is_using_mro() && mro::get_mro($stash_name) eq 'c3' ) {
        B::C::make_c3($stash_name);
    }

    return $sym;
}

1;
