print "1..1\n";
BEGIN { no strict; *Foo:: = *{"Wazza::"} }

package Foo {
    sub mysub { print "ok\n"; }
}
Foo::mysub();
