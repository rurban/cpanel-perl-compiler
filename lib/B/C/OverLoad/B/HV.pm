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
use B::C::File qw/init xpvhvsect svsect sharedhe decl init1 init2/;
use B::C::Helpers qw/read_utf8_string strlen_flags is_using_mro/;
use B::C::Helpers::Symtable qw/objsym savesym/;
use B::C::Save::Hek qw/save_shared_he/;

my ($swash_ToCf);

sub swash_ToCf_value {    # NO idea what it s ??
    return $swash_ToCf;
}

sub do_save {
    my ( $hv, $fullname ) = @_;

    $fullname = '' unless $fullname;
    my $name = $hv->NAME;
    my $magic;
    my $sym;

    my $sv_list_index = svsect()->add("FAKE_HV");
    $sym = savesym( $hv, "(HV*)&sv_list[$sv_list_index]" );

    # could also simply use: savesym( $hv, sprintf( "s\\_%x", $$hv ) );

    # reduce the content
    # remove values from contents we are not going to save
    my %contents = $hv->ARRAY;
    if (%contents) {
        local $B::C::const_strings = $B::C::const_strings;

        # Walk the values and save them into symbols
        foreach my $key ( sort keys %contents ) {

            # $name means it is a stash.
            if ( $name && !B::C::Optimizer::UnusedPackages::gv_was_in_original_program( $name . '::' . $key ) ) {
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

    {    # add hash content even if the hash is empty [ maybe only for %INC ??? ]
        init()->no_split;
        init()->sadd( qq[{\n] . q{HvSETUP(%s, %d);}, $sym, $max + 1 );

        foreach my $key ( sort keys %contents ) {

            # Insert each key into the hash.
            my $shared_he = save_shared_he($key);
            init()->sadd( q{HvAddEntry(%s, %s, %s, %d);}, $sym, $contents{$key}, $shared_he, $max );

            #debug( hv => q{ HV key "%s" = %s}, $key, $value );
        }

        # save the iterator in hv_aux (and malloc it)
        init()->sadd( "HvRITER_set(%s, %d);", $sym, -1 );    # saved $hv->RITER

        init()->add("}");
        init()->split;
    }

    $magic = $hv->save_magic($fullname);
    init()->add("SvREADONLY_on($sym);") if $hv->FLAGS & SVf_READONLY;
    if ( $magic =~ /c/ ) {

        # defer AMT magic of XS loaded stashes
        my ( $cname, $len, $utf8 ) = strlen_flags($name);
        init2()->add(qq[$sym = gv_stashpvn($cname, $len, GV_ADDWARN|GV_ADDMULTI|$utf8);]);
    }

    if ( $name and is_using_mro() and mro::get_mro($name) eq 'c3' ) {
        B::C::make_c3($name);
    }

    if ($name) {
        $hv->do_special_stash_stuff( $name, $sym );
    }

    return $sym;
}

sub get_max_hash_from_keys {
    my ( $keys, $default ) = @_;
    $default ||= 7;

    return $default if !$keys or $keys <= $default;    # default hash max value

    return 2**( int( log($keys) / log(2) ) + 1 ) - 1;
}

sub do_special_stash_stuff {
    my ( $hv, $name, $sym ) = @_;

    # SVf_AMAGIC is set on almost every stash until it is
    # used.  This forces a transversal of the stash to remove
    # the flag if its not actually needed.
    # fix overload stringify
    # Gv_AMG: potentially removes the AMG flag
    if ( $hv->FLAGS & SVf_AMAGIC and length($name) and $hv->Gv_AMG ) {
        init2()->sadd( "mro_isa_changed_in(%s);  /* %s */", $sym, $name );
    }

    # Add aliases if namecount > 1 (GH #331)
    # There was no B API for the count or multiple enames, so I added one.
    my @enames = $hv->ENAMES;
    if ( @enames > 1 ) {
        debug( hv => "Saving for $name multiple enames: ", join( " ", @enames ) );
        my $name_count = $hv->name_count;

        my $hv_max_plus_one = $hv->MAX + 1;

        # If the stash name is empty xhv_name_count is negative, and names[0] should
        # be already set. but we rather write it.
        init()->no_split;

        # unshift @enames, $name if $name_count < 0; # stashpv has already set names[0]
        init()->add(
            "if (!SvOOK($sym)) {",    # hv_auxinit is not exported
            "  HE **a;",
            sprintf( "  Newxz(a, %d + sizeof(struct xpvhv_aux), HE*);", $hv_max_plus_one ),
            "  SvOOK_on($sym);",
            "}",
            "{",
            "  struct xpvhv_aux *aux = HvAUX($sym);",
            sprintf( "  Newx(aux->xhv_name_u.xhvnameu_names, %d, HEK*);", scalar $name_count ),
            sprintf( "  aux->xhv_name_count = %d;",                       $name_count )
        );
        my $i = 0;
        while (@enames) {
            my ( $cstring, $cur, $utf8 ) = strlen_flags( shift @enames );
            init()->sadd(
                "  aux->xhv_name_u.xhvnameu_names[%u] = share_hek(%s, %d, 0);",
                $i++, $cstring, $utf8 ? -$cur : $cur
            );
        }
        init()->add("}");
        init()->split;
    }

    # issue 79, test 46: save stashes to check for packages.
    # and via B::STASHGV we only save stashes for stashes.
    # For efficiency we skip most stash symbols unless -fstash.
    # However it should be now safe to save all stash symbols.
    # $fullname !~ /::$/ or

    my $magic = $hv->save_magic( '%' . $name . '::' );    #symtab magic set in PMOP #188 (#267)
    if ( is_using_mro() && mro::get_mro($name) eq 'c3' ) {
        B::C::make_c3($name);
    }

    return $sym;
}

1;
