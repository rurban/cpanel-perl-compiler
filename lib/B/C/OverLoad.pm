package B::C::OverLoad;

use B::C::OverLoad::B::BM          ();    # special case
use B::C::OverLoad::B::LEXWARN     ();    # not using objsym or savesym
use B::C::OverLoad::B::OBJECT      ();
use B::C::OverLoad::B::OP          ();
use B::C::OverLoad::B::PADLIST     ();
use B::C::OverLoad::B::PADNAME     ();
use B::C::OverLoad::B::PADNAMELIST ();
use B::C::OverLoad::B::PADOP       ();
use B::C::OverLoad::B::PMOP        ();
use B::C::OverLoad::B::PV          ();
use B::C::OverLoad::B::PVIV        ();
use B::C::OverLoad::B::PVLV        ();
use B::C::OverLoad::B::PVMG        ();
use B::C::OverLoad::B::PVNV        ();
use B::C::OverLoad::B::PVOP        ();
use B::C::OverLoad::B::REGEXP      ();
use B::C::OverLoad::B::RV          ();
use B::C::OverLoad::B::SPECIAL     ();
use B::C::OverLoad::B::SV          ();
use B::C::OverLoad::B::SVOP        ();
use B::C::OverLoad::B::UNOP        ();
use B::C::OverLoad::B::UNOP_AUX    ();
use B::C::OverLoad::B::UV          ();

BEGIN {
    require B::C::OP;    # needs to be loaded first: provide common helper for all OPs

    my @OPs = qw{AV BINOP COP CV GV IV HV IO LISTOP LOGOP LOOP
      METHOP NULL NV
    };

    # do not use @ISA, just plug what we need
    foreach my $op (@OPs) {
        no strict 'refs';
        my $pkg      = qq{B::$op};
        my $overload = "B::C::OverLoad::$pkg";
        eval qq{require $overload} or die $@;
        my $save = $pkg . q{::save};
        *$save = \&B::C::OP::save;
    }
}

1;
