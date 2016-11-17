#!./perl

print "1..1\n";

sub kt {
    return '4' if $_[0] eq '09028623';
}

# Nested EVAL using PL_curpm (via $1 or friends)
my $re;
our $grabit = qr/ ([0-6][0-9]{7}) (??{ kt $1 }) [890] /x;
$re = qr/^ ( (??{ $grabit }) ) $ /x;

my @res = '0902862349' =~ $re;
print "ok 1 - PL_curpm is set properly on nested eval\n" if join( "-", @res ) eq "0902862349";
