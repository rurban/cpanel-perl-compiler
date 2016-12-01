package B::C::Optimizer::UnusedPackages;

use strict;

# use Exporter ();
# use B::C::Config;    # import everything
# B::C::Packages Aliases

sub package_was_compiled_in {
    my $package = shift;

    my $was = was_compiled_in( $package, 0 );

    #    print STDERR "$package not compiled\n" unless $was;

    return $was;
}

sub sub_was_compiled_in {
    return was_compiled_in( shift, 1 );
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
