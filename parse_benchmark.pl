#!/usr/bin/perl

my %type_times;
my $last;

# default values
my ( $start, $stop ) = ( 'preinit', 'preinit1' );
my $total = 0;

my @args = @ARGV;
$start = shift @args if @args;
$stop  = shift @args if @args;

while (<STDIN>) {
    my ( $time, $type ) = parse();

    if ( $type eq $start ) {
        $last = $time;
        next;
    }

    last if $type eq $stop;
    next unless $last;

    next unless length $type;

    my $delta = $time - $last;
    $total += $delta;
    $type_times{$type} ||= {};
    $type_times{$type}->{start} ||= $time;
    $type_times{$type}->{total} += $delta;
    $type_times{$type}->{counter}++;
    $last = $time;
}

delete $type_times{'START'};

printf "# Parse from '%s' to '%s' - %d usec\n", $start, $stop, ( $last - $type_times{$start}->{start} ) / 1_000;

foreach my $type ( sort { $type_times{$a}->{total} <=> $type_times{$b}->{total} } keys %type_times ) {
    printf(
        "%15s = %8d usec - %4d hits - %02.2f %%\n",
        $type,
        int( $type_times{$type}->{total} / 1_000 ),
        $type_times{$type}->{counter},
        $total ? $type_times{$type}->{total} / $total * 100 : 0,
    );
}

sub parse {
    m/^--USECONDS (\d+)\s+==\s+(.+)\n/ or return;
    return ( "$1", "$2" );
}
