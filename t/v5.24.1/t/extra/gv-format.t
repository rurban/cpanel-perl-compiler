
package main;

our @X = (1..42);

print "1..1\n";

format X =
@< @|@>>>>>>>>>>>>>
              $str,  $sep,  $msg
.

$str = "oktrash";
$msg = q{using a format};
$sep = q{-};
$~ = 'X';
write;