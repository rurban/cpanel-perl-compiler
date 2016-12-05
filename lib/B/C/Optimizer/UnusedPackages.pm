package B::C::Optimizer::UnusedPackages;

use strict;

# use Exporter ();
# use B::C::Config;    # import everything
# B::C::Packages Aliases

sub stash_fixup {
    my $stash = $B::C::settings->{'starting_stash'};

    delete $stash->{'B::'};    # What if they use B::Devel

    die if scalar keys %{ $stash->{'O::'} } != 7;
    delete $stash->{'O::'};

    delete $stash->{'Carp::'}      if ( scalar keys %{ $stash->{'Carp::'} } == 1 );
    delete $stash->{'UNIVERSAL::'} if ( scalar keys %{ $stash->{'UNIVERSAL::'} } == 4 );

    my %empty_packages = (
        'version'   => 30,
        'utf8'      => 8,
        'DB'        => 2,
        're'        => 5,
        'mro'       => 1,
        'constant'  => 1,
        'Regexp'    => 1,
        'CORE'      => 1,
        'Internals' => 4,
        'Exporter'  => 0,
    );
    foreach my $package ( keys %empty_packages ) {
        my $name = $package . '::';
        next unless scalar keys %{ $stash->{$name} } <= $empty_packages{$package};
        next if $stash->{$name}->{'VERSION'};
        delete $stash->{$name};
    }

    delete $stash->{$_} foreach qw(stderr stdin stdout STDERR STDIN STDOUT ENV 0 1 2 3 4 5 6 7 8 9 @ - + INC ARGV BEGIN _ " \\ ]), q{,}, '/';

    # $^X, $^R $^H
    delete $stash->{ chr($_) } foreach qw(24 18 8);

    # $^R + E_TRIE_MAXBUF
    delete $stash->{ chr(18) . "E_TRIE_MAXBUF" };

    foreach my $key ( keys %$stash ) {
        delete $stash->{$key} if $key =~ m{^_<};
    }

    #eval 'use Data::Dumper; $Data::Dumper::Sortkeys=1';    print STDERR Data::Dumper::Dumper($stash); die;
    return;
}

sub package_was_compiled_in {
    my $package = shift;

    my $was = was_compiled_in( $package, 0 );

    #    print STDERR "$package not compiled\n" unless $was;

    return $was;
}

sub gv_was_in_original_program {
    my $package = shift;
    $package =~ s/^main:://;
    return 1 if $package eq '';     # %main::
    return 0 if $package eq '0';    # $0

    my $was;
    if ( $package =~ m/\S::$/ ) {
        $was = was_compiled_in( $package, 0 );
    }
    else {
        $was = was_compiled_in( $package, 1 );
    }

    #    print STDERR "GV $package not compiled\n" unless $was;

    return $was;
}

sub was_compiled_in {
    my $fullname = shift or die;
    my $sub_check = shift;

    return 0 if $fullname =~ qr{^::};
    $fullname =~ s/^main:://;

    my @path = split( "::", $fullname );
    return 1 if ( $fullname eq 'main' );    # main:: was compiled in.

    my $stash = $B::C::settings->{'starting_stash'};

    my $subname = '';
    $subname = pop @path if $sub_check;

    return 0 if ( scalar @path == 2 && $path[0] eq 'B' && $path[1] eq 'C' );
    return 0 if ( scalar @path == 1 && $path[0] eq 'O' );
    return 0 if ( scalar @path == 1 && $path[0] eq '__ANON__' );

    return 0 if ( $subname =~ tr/[]{}() // );                                         # This doesn't appear to be a sub.
    return 0 if ( $fullname =~ m/^Internals::/ );
    return 1 if ( $fullname =~ m/^DynaLoader::/ && $B::C::settings->{'needs_xs'} );
    return 1
      if $fullname =~ /^Config::(AUTOLOAD|DESTROY|TIEHASH|FETCH|import)$/
      && exists $stash->{"Config::"}->{'Config'};
    return 1 if $fullname =~ /Config::[^:]+$/ && exists $B::C::settings->{'starting_INC'}->{'Config_heavy.pl'};
    return 1 if $fullname =~ /Errno::[^:]+$/;

    #return 0 if ( $fullname =~ /NDBM_File::[^:]+$/ );
    # save all utf8 functions if utf8_heavy is loaded
    return 1 if $fullname =~ /utf8::[^:]+$/ && exists $stash->{"utf8::"}->{'SWASHNEW'};
    return 1 if $fullname =~ /re::[^:]+$/ and $B::C::settings->{'uses_re'};

    foreach my $step (@path) {    # note $step can be empty: a::::b
        if ( !exists $stash->{"${step}::"} ) {
            return 0;
        }
        $stash = $stash->{"${step}::"};
    }
    if ( !$sub_check ) {
        return $stash ? 1 : 0;
    }

    my $ret = $stash->{$subname} ? 1 : 0;

    return $ret;
}

1;
