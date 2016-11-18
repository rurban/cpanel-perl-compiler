package B::C::Save::Hek;

use strict;

use B::C::Config;
use B::C::File qw(sharedhe);
use B::C::Helpers qw/strlen_flags/;

use Exporter ();
our @ISA = qw(Exporter);

our @EXPORT_OK = qw/save_shared_he/;

my %saved_shared_hash;

sub save_shared_he {
    my $key = shift;

    return 'NULL' unless defined $key;
    return $saved_shared_hash{$key} if $saved_shared_hash{$key};

    my ( $cstr, $cur, $utf8 ) = strlen_flags($key);

    #$cur *= -1 if $utf8;

    my $index = sharedhe()->index() + 1;

    sharedhe()->add( sprintf( "STATIC_SHARED_HE_ALLOC(%d, %d, %s, %d);", $index, $cur, $cstr, $utf8 ? 1 : 0 ) );

    return $saved_shared_hash{$key} = sprintf( q{sharedhe_list[%d]}, $index );
}

1;
