package main;

our %hash = (1..4);

print "1..2\n";

print "ok 1 - scalar keys %hash\n" if scalar keys %hash == 2;
print "ok 2 - access a hash value\n" if $hash{3} == 4;
