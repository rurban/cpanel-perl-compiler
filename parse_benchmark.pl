#!/usr/bin/perl

use Data::Dumper;
my %type_times;

my $last;

while (<STDIN>) {
    my ( $time, $type ) = parse();

    if ( $type eq 'preinit' ) {
        $last = $time;
        next;
    }

    last if ( $type eq 'preinit1' );
    next unless $last;

    $type_times{$type} += $time - $last;
    $last = $time;
}

foreach my $type ( sort { $type_times{$a} <=> $type_times{$b} } keys %type_times ) {
    printf( "%15s = %8d\n", $type, int( $type_times{$type} / 1000 ) );
}

sub parse {
    m/^--USECONDS (\d+)\s+==\s+(.+)\n/ or return;
    return ( "$1", "$2" );
}
