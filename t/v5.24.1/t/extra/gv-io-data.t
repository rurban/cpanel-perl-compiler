#!perl

print "1..3\n";
print "ok 1 - Program starts\n";
while (my $line = <DATA>) {
    print $line;
}

__DATA__
ok 2 - DATA Section is legible
ok 3 - DATA Section is legible line 2
