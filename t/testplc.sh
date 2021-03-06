#!/bin/bash
# Usage: 
# for p in 5.6.2 5.8.9d 5.10.1 5.11.2; do make -q clean >/dev/null; perl$p Makefile.PL; t/testplc.sh -q -c; done
# use the actual perl from the Makefile (perld, perl5.10.0, perl5.8.8, perl5.11.0, ...)
function help {
  echo "t/testplc.sh [OPTIONS] [1-$ntests]"
  echo " -s                 skip all B:Debug, roundtrips and options"
  echo " -S                 skip all roundtrips and options but -S and Concise"
  echo " -c                 continue on errors"
  echo " -o                 orig. no -Mblib. only for 5.6 and 5.8"
  echo " -q                 quiet"
  echo " -v                 avoid -MO,-qq"
  echo " -h                 help"
  echo "t/testplc.sh -q -s -c <=> perl -Mblib t/bytecode.t"
  echo "Without arguments try all $ntests tests. Else the given test numbers."
}

# use the actual perl from the Makefile (perl5.8.8, 
# perl5.10.0d-nt, perl5.11.0, ...)
PERL=`grep "^PERL =" Makefile|cut -c8-`
PERL=${PERL:-perl}
VERS=`echo $PERL|sed -e's,.*perl,,' -e's,.exe$,,'`
D="`$PERL -e'print (($] < 5.007) ? q(256) : q(v))'`"
v518=`$PERL -e'print (($] < 5.018)?0:1)'`

function init {
    # test what? core or our module?
    Mblib="`$PERL -e'print (($] < 5.008) ? q() : q(-Iblib/arch -Iblib/lib))'`"
    #Mblib=${Mblib:--Mblib} # B::C is now fully 5.6+5.8 backwards compatible
    OCMD="$PERL $Mblib -MO=Bytecode,"
    QOCMD="$PERL $Mblib -MO=-qq,Bytecode,"
    ICMD="$PERL $Mblib -MByteLoader"
    if [ "$D" = "256" ]; then QOCMD=$OCMD; fi
    if [ "$Mblib" = " " ]; then VERS="${VERS}_global"; fi
}

function pass {
    echo -e -n "\033[1;32mPASS \033[0;0m"
    echo $*
}
function fail {
    echo -e -n "\033[1;31mFAIL \033[0;0m"
    echo $*
}
function bcall {
    o=$1
    opt=${2:-s}
    ext=${3:-plc}
    optf=$(echo $opt|sed 's/,-//g')
    [ -n "$Q" ] || echo ${QOCMD}-$opt,-o${o}${optf}_${VERS}.${ext} ${o}.pl
    ${QOCMD}-$opt,-o${o}${optf}_${VERS}.${ext} ${o}.pl
}
function btest {
  n=$1
  o="bytecode$n"
  if [ -z "$2" ]; then
      if [ "$n" = "08" ]; then n=8; fi 
      if [ "$n" = "09" ]; then n=9; fi
      echo "${tests[${n}]}" > ${o}.pl
      test -z "${tests[${n}]}" && exit
      str="${tests[${n}]}"
  else 
      echo "$2" > ${o}.pl
  fi
  #bcall ${o} O6
  rm ${o}_s_${VERS}.plc 2>/dev/null
  
  # annotated assembler
  if [ -z "$SKIP" -o -n "$SKI" ]; then
    if [ "$Mblib" != " " ]; then 
	bcall ${o} S,-s asm 1
	bcall ${o} S,-k asm 1
	bcall ${o} S,-i,-b asm 1
    fi
  fi
  if [ "$Mblib" != " " -a -z "$SKIP" ]; then 
    m=${o}s_${VERS}
    rm ${m}.disasm ${o}_${VERS}.concise ${o}_${VERS}.dbg 2>/dev/null
    bcall ${o} s
    [ -n "$Q" ] || echo $PERL $Mblib script/disassemble $m.plc \> ${m}.disasm
    $PERL $Mblib script/disassemble $m.plc > ${m}.disasm
    [ -n "$Q" ] || echo ${ICMD} ${m}.plc
    res=$(${ICMD} ${m}.plc)
    if [ "X${result[$n]}" = "X" ]; then result[$n]='ok'; fi
    if [ "X$res" != "X${result[$n]}" ]; then
      fail "./${m}.plc" "'$str' => '$res' Expected: '${result[$n]}'"
    fi

    # understand annotations
    m=${o}S_${VERS}
    [ -n "$Q" ] || echo $PERL $Mblib script/assemble ${o}s_${VERS}.disasm \> $m.plc
    $PERL $Mblib script/assemble ${o}s_${VERS}.disasm > $m.plc
    # full assembler roundtrips
    [ -n "$Q" ] || echo $PERL $Mblib script/disassemble $m.plc \> $m.disasm
    $PERL $Mblib script/disassemble $m.plc > $m.disasm
    md=${o}SD_${VERS}
    [ -n "$Q" ] || echo $PERL $Mblib script/assemble $m.disasm \> ${md}.plc
    $PERL $Mblib script/assemble $m.disasm > ${md}.plc
    [ -n "$Q" ] || echo $PERL $Mblib script/disassemble ${md}.plc \> ${o}SDS_${VERS}.disasm
    $PERL $Mblib script/disassemble ${md}.plc > ${o}SDS_${VERS}.disasm

    bcall ${o} i,-b
    m=${o}ib_${VERS}
    $PERL $Mblib script/disassemble ${m}.plc > ${m}.disasm
    [ -n "$Q" ] || echo ${ICMD} ${m}.plc
    res=$(${ICMD} ${m}.plc)
    if [ "X$res" = "X${result[$n]}" ]; then
      pass "./${m}.plc" "=> '$res'"
    else
      fail "./${m}.plc" "'$str' => '$res' Expected: '${result[$n]}'"
    fi

    bcall ${o} k
    m=${o}k_${VERS}
    $PERL $Mblib script/disassemble ${m}.plc > ${m}.disasm
    [ -n "$Q" ] || echo ${ICMD} ${m}.plc
    res=$(${ICMD} ${m}.plc)
    if [ "X$res" != "X${result[$n]}" ]; then
      fail "./${m}.plc" "'$str' => '$res' Expected: '${result[$n]}'"
    fi

    [ -n "$Q" ] || echo $PERL $Mblib -MO=${qq}Debug,-exec ${o}.pl -o ${o}_${VERS}.dbg
    [ -n "$Q" ] || $PERL $Mblib -MO=${qq}Debug,-exec ${o}.pl > ${o}_${VERS}.dbg
  fi
  if [ -z "$SKIP" -o -n "$SKI" ]; then
    # 5.8 has a bad concise
    [ -n "$Q" ] || echo $PERL $Mblib -MO=${qq}Concise,-exec ${o}.pl -o ${o}_${VERS}.concise
    $PERL $Mblib -MO=${qq}Concise,-exec ${o}.pl > ${o}_${VERS}.concise
  fi
  if [ -z "$SKIP" ]; then
    if [ "$Mblib" != " " ]; then 
      #bcall ${o} TI
      bcall ${o} H
      m="${o}H_${VERS}"
      [ -n "$Q" ] || echo $PERL $Mblib ${m}.plc
      res=$($PERL $Mblib ${m}.plc)
      if [ "X$res" != "X${result[$n]}" ]; then
          fail "./${m}.plc" "'$str' => '$res' Expected: '${result[$n]}'"
      fi
    fi
  fi
  if [ "$Mblib" != " " ]; then
    # -s ("scan") should be the new default
    [ -n "$Q" ] || echo ${OCMD}-s,-o${o}.plc ${o}.pl
    ${OCMD}-s,-o${o}.plc ${o}.pl || (test -z $CONT && exit)
  else
    # No -s with 5.6
    [ -n "$Q" ] || echo ${OCMD}-o${o}.plc ${o}.pl
    ${OCMD}-o${o}.plc ${o}.pl || (test -z $CONT && exit)
  fi
  [ -n "$Q" ] || echo $PERL $Mblib script/disassemble ${o}.plc -o ${o}.disasm
  $PERL $Mblib script/disassemble ${o}.plc > ${o}.disasm
  [ -n "$Q" ] || echo ${ICMD} ${o}.plc
  res=$(${ICMD} ${o}.plc)
  if [ "X$res" = "X${result[$n]}" ]; then
      pass "./${o}.plc" "=> '$res'"
  else
      fail "./${o}.plc" "'$str' => '$res' Expected: '${result[$n]}'"
      if [ -z "$Q" ]; then
          echo -n "Again with -Dv? (or Ctrl-Break)"
          read
          echo ${ICMD} -D$D ${o}.plc; ${ICMD} -D$D ${o}.plc
      fi
      test -z $CONT && exit
  fi
}

ntests=350
declare -a tests[$ntests]
declare -a result[$ntests]
tests[1]="print 'hi'"
result[1]='hi'
tests[2]='for (1,2,3) { print if /\d/ }'
result[2]='123'
tests[3]='$_ = "xyxyx"; %j=(1,2); s/x/$j{print("z")}/ge; print $_'
result[3]='zzz2y2y2'
tests[4]='$_ = "xyxyx"; %j=(1,2); s/x/$j{print("z")}/g; print $_'
if [[ $v518 -gt 0 ]]; then result[4]='zzz2y2y2'; else result[4]='z2y2y2'; fi
tests[5]='print split /a/,"bananarama"'
result[5]='bnnrm'
tests[6]="{package P; sub x {print 'ya'} x}"
result[6]='ya'
tests[7]='@z = split /:/,"b:r:n:f:g"; print @z'
result[7]='brnfg'
tests[8]='sub AUTOLOAD { print 1 } &{"a"}()'
result[8]='1'
tests[9]='my $l = 3; $x = sub { print $l }; &$x'
result[9]='3'
tests[10]='my $i = 1;
my $foo = sub {
  $i = shift if @_
}; print $i;
print &$foo(3),$i;'
result[10]='133'
# index: do fbm_compile or not
tests[11]='$x="Cannot use"; print index $x, "Can"'
result[11]='0'
tests[12]='my $i=6; eval "print \$i\n"'
result[12]='6'
tests[13]='BEGIN { %h=(1=>2,3=>4) } print $h{3}'
result[13]='4'
tests[14]='open our $T,"a"; print "ok";'
result[14]='ok'
tests[15]='print <DATA>
__DATA__
a
b'
result[15]='a
b'
tests[16]='BEGIN{tie @a, __PACKAGE__;sub TIEARRAY {bless{}} sub FETCH{1}}; print $a[1]'
result[16]='1'
tests[17]='my $i=3; print 1 .. $i'
result[17]='123'
# custom key sort
tests[18]='my $h = { a=>3, b=>1 }; print sort {$h->{$a} <=> $h->{$b}} keys %$h'
result[18]='ba'
# fool the sort optimizer by my $p
tests[19]='print sort { my $p; $b <=> $a } 1,4,3'
result[19]='431'
# not repro: something like this is broken in original 5.6 (Net::DNS::ZoneFile::Fast)
# see new test 33
tests[20]='$a="abcd123";my $r=qr/\d/;print $a =~ $r;'
result[20]='1'
# broken on early alpha and 5.10: run-time labels.
tests[21]='sub skip_on_odd{next NUMBER if $_[0]% 2}NUMBER:for($i=0;$i<5;$i++){skip_on_odd($i);print $i;}'
result[21]='024'
# broken in original perl 5.6
tests[22]='my $fh; BEGIN { open($fh,"<","/dev/null"); } print "ok";';
# broken in perl 5.8
tests[23]='package MyMod; our $VERSION = 1.3; print "ok";'
# works in original perl 5.6, broken with latest B::C in 5.6, 5.8
tests[24]='sub level1{return(level2()?"fail":"ok")} sub level2{0} print level1();'
# enforce custom ncmp sort and count it. fails as CC in all. How to enforce icmp?
# <=5.6 qsort needs two more passes here than >=5.8 merge_sort
# 5.12 got it backwards and added 4 more passes.
tests[25]='print sort { $i++; $b <=> $a } 1..4'
result[25]="4321"
# lvalue sub
tests[26]='sub a:lvalue{my $a=26; ${\(bless \$a)}}sub b:lvalue{${\shift}}; print ${a(b)}';
result[26]="26"
# xsub constants (constant folded). newlib: 0x200, glibc: 0x100
tests[27]='use Fcntl ();my $a=Fcntl::O_CREAT(); print "ok" if ( $a >= 64 && &Fcntl::O_CREAT >= 64 );'
# require $fname
tests[28]='my($fname,$tmp_fh);while(!open($tmp_fh,">",($fname=q{ccode28_} . rand(999999999999)))){$bail++;die "Failed to create a tmp file after 500 tries" if $bail>500;}print {$tmp_fh} q{$x="ok";1;};close($tmp_fh);sleep 1;require $fname;END{unlink($fname);};print $x;'
# multideref with static index and sv and dynamic gv ptrs
tests[29]='my (%b,%h); BEGIN { %b=(1..8);@a=(1,2,3,4); %h=(1=>2,3=>4) } $i=0; my $l=-1; print $h->{$b->{3}},$h->{$a[-1]},$a[$i],$a[$l],$h{3}'
result[29]='144'
# special old IO handling
tests[291]='use IO;print "ok"'
# run-time context of .., fails in CC
tests[30]='@a=(4,6,1,0,0,1);sub range{(shift @a)..(shift @a)}print range();while(@a){print scalar(range())}'
result[30]='456123E0'
# AUTOLOAD w/o goto xsub
tests[31]='package MockShell;sub AUTOLOAD{my $p=$AUTOLOAD;$p=~s/.*:://;print(join(" ",$p,@_),";");} package main; MockShell::date();MockShell::who("am","i");MockShell::ls("-l");'
result[31]='date;who am i;ls -l;'
# CC entertry/jmpenv_jump/leavetry
tests[32]='eval{print "1"};eval{die 1};print "2";'
result[32]='12'
# C qr test was broken in 5.6 -- needs to load an actual file to test. See test 20.
# used to error with Can't locate object method "save" via package "U??WVS?-" (perhaps you forgot to load "U??WVS?-"?) at /usr/lib/perl5/5.6.2/i686-linux/B/C.pm line 676.
# fails with new constant only. still not repro (r-magic probably)
tests[33]='BEGIN{unshift @INC,("t");} use qr_loaded_module; print "ok" if qr_loaded_module::qr_called_in_sub("name1")'
# init of magic hashes. %ENV has e magic since a0714e2c perl.c
# (Steven Schubiger      2006-02-03 17:24:49 +0100 3967) i.e. 5.8.9 but not 5.8.8
tests[34]='my $x=$ENV{TMPDIR};print "ok"'
# static method_named. fixed with 1.16
tests[35]='package dummy;my $i=0;sub meth{print $i++};package main;dummy->meth(1);my dummy $o = bless {},"dummy";$o->meth("const");my $meth="meth";$o->$meth("const");dummy->$meth("const");dummy::meth("dummy","const")'
result[35]='01234'
# HV self-ref
tests[36]='my ($rv, %hv); %hv = ( key => \$rv ); $rv = \%hv; print "ok";'
# AV self-ref
tests[37]='my ($rv, @av); @av = ( \$rv ); $rv = \@av; print "ok";'
# constant autoload loop crash test
tests[38]='for(1 .. 1024) { if (open(my $null_fh,"<","/dev/null")) { seek($null_fh,0,SEEK_SET); close($null_fh); $ok++; } }if ($ok == 1024) { print "ok"; }'
# check re::is_regexp, and on 5.12 if being upgraded to SVt_REGEXP
usere="`$PERL -e'print (($] < 5.011) ? q(use re;) : q())'`"
tests[39]=$usere'$a=qr/x/;print ($] < 5.010?1:re::is_regexp($a))'
result[39]='1'
# String with a null byte -- used to generate broken .c on 5.6.2 with static pvs
tests[40]='my $var="this string has a null \\000 byte in it";print "ok";'
# Shared scalar, n magic. => Don't know how to handle magic of type \156.
usethreads="`$PERL -MConfig -e'print ($Config{useithreads} ? q(use threads;) : q())'`"
#usethreads='BEGIN{use Config; unless ($Config{useithreads}) {print "ok"; exit}} '
#;threads->create(sub{$s="ok"})->join;
# not yet testing n, only P
tests[41]=$usethreads'use threads::shared;{my $s="ok";share($s);print $s}'
# Shared aggregate, P magic
tests[42]=$usethreads'use threads::shared;my %h : shared; print "ok"'
# Aggregate element, n + p magic
tests[43]=$usethreads'use threads::shared;my @a : shared; $a[0]="ok"; print $a[0]'
# perl #72922 (5.11.4 fails with magic_killbackrefs)
tests[44]='use Scalar::Util "weaken";my $re1=qr/foo/;my $re2=$re1;weaken($re2);print "ok" if $re3=qr/$re1/;'
# test dynamic loading
tests[45]='use Data::Dumper ();Data::Dumper::Dumpxs({});print "ok";'
# issue 79: Exporter:: stash missing in main::
#tests[46]='use Exporter; if (exists $main::{"Exporter::"}) { print "ok"; }'
tests[46]='use Exporter; print "ok" if %main::Exporter::'
#tests[46]='use Exporter; print "ok" if scalar(keys(%main::Exporter::)) > 2'
# non-tied av->MAGICAL
tests[47]='@ISA=(q(ok));print $ISA[0];'
# END block del_backref with bytecode only
tests[48]='my $s=q{ok};END{print $s}'
# even this failed until r1000, overlarge AvFILL=3 endav
#tests[48]='print q(ok);END{}'
# no-fold
tests[49]='print q(ok) if "test" =~ /es/i;'
# @ISA issue 64
tests[50]='package Top;sub top{q(ok)};package Next;our @ISA=qw(Top);package main;print Next->top();'
# XXX TODO sigwarn $w = B::NULL without -v
tests[51]='$SIG{__WARN__}=sub{print "ok"};warn 1;'
# check if general signals work
tests[511]='BEGIN{$SIG{USR1}=sub{$w++;};} kill USR1 => $$; print q(ok) if $w'
tests[68]='package A;sub test{use Data::Dumper();$_ =~ /^(.*?)\d+$/;"Some::Package"->new();}print q(ok);'
#-------------
# issue27
tests[70]='require LWP::UserAgent;print q(ok);'
# issue24
tests[71]='dbmopen(%H,q(f),0644);print q(ok);'
tests[81]='%int::;    #create int package for types
sub x(int,int) { @_ } #cvproto
my $o = prototype \&x;
if ($o eq "int,int") {print "o"}else{print $o};
sub y($) { @_ } #cvproto
my $p = prototype \&y;
if ($p eq q($)) {print "k"}else{print $p};
require bytes;
sub my::length ($) { # possible prototype mismatch vs _
  if ( bytes->can(q(length)) ) {
     *length = *bytes::length;
     goto &bytes::length;
  }
  return CORE::length( $_[0] );
}
print my::length($p);'
result[81]='ok1'
tests[90]='my $s = q(test string);
$s =~ s/(?<first>test) (?<second>string)/\2 \1/g;
print q(o) if $s eq q(string test);
q(test string) =~ /(?<first>\w+) (?<second>\w+)/;
print q(k) if $+{first} eq q(test);'
tests[901]='my %errs = %!; # t/op/magic.t Errno compiled in
print q(ok) if defined ${"!"}{ENOENT};'
tests[902]='my %errs = %{"!"}; # t/op/magic.t Errno to be loaded at run-time
print q(ok) if defined ${"!"}{ENOENT};'
# issue #199
tests[903]='"abc" =~ /(.)./; print "ok" if "21" eq join"",@+;'
# issue #220
tests[904]='my $content = "ok\n";
while ( $content =~ m{\w}g ) {
    $_ .= "$-[0]$+[0]";
}
print "ok" if $_ eq "0112";'
# IO handles
tests[91]='# issue59
use strict;
use warnings;
use IO::Socket;
my $remote = IO::Socket::INET->new( Proto => "tcp", PeerAddr => "perl.org", PeerPort => "80" );
print $remote "GET / HTTP/1.0" . "\r\n\r\n";
my $result = <$remote>;
$result =~ m|HTTP/1.1 200 OK| ? print "ok" : print $result;
close $remote;'
tests[93]='#SKIP
my ($pid, $out, $in);
BEGIN {
  local(*FPID);
  $pid = open(FPID, "echo <<EOF |");    # DIE
  open($out, ">&STDOUT");		# EASY
  open(my $tmp, ">", "pcc.tmp");	# HARD to get filename, WARN
  print $tmp "test\n";
  close $tmp;				# OK closed
  open($in, "<", "pcc.tmp");		# HARD to get filename, WARN
}
# === run-time ===
print $out "o";
kill 0, $pid; 			     # BAD! warn? die?
print "k" if "test" eq read $in, my $x, 4;
unlink "pcc.tmp";
'
result[93]='o'
tests[931]='my $f;BEGIN{open($f,"<README");}read $f,my $in, 2; print "ok"'
tests[932]='my $f;BEGIN{open($f,">&STDOUT");}print $f "ok"'
tests[95]='use IO::Socket::SSL();
my IO::Handle $handle = IO::Socket::SSL->new(SSL_verify_mode =>0);
$handle->blocking(0);
print "ok";'
tests[96]='defined(&B::OP::name) || print q(ok)'
tests[97]='use v5.12; print q(ok);'
result[97]='ok'
tests[971]='use v5.6; print q(ok);'
result[971]='ok'
tests[98]='BEGIN{$^H{feature_say} = 1;}
sub test { eval(""); }
print q(ok);'
result[98]='ok'
tests[105]='package A; use Storable qw/dclone/; my $a = \""; dclone $a; print q(ok);'
result[105]='ok'
if [[ $v518 -gt 0 ]]; then
  tests[130]='no warnings "experimental::lexical_subs";use feature "lexical_subs";my sub p{q(ok)}; my $a=\&p;print p;'
fi
tests[135]='"to" =~ /t(?{ print "ok"})o/;'
tests[138]='print map { chr $_ } qw/97 98 99/;'
result[138]='abc'
tests[140]='my %a;print "ok" if !%a;'
#tests[141]='print "ok" if "1" > 0'
tests[141]='@x=(0..1);print "ok" if $#x == "1"'
tests[142]='$_ = "abc\x{1234}";chop;print "ok" if $_ eq "abc"'
tests[143]='BEGIN {
  package Net::IDN::Encode;
  our $DOT = qr/[\.]/; #works with my!
  my $RE  = qr/xx/;
  sub domain_to_ascii {
    my $x = shift || "";
    $x =~ m/$RE/o;
    return split( qr/($DOT)/o, $x);
  }
}
package main;
Net::IDN::Encode::domain_to_ascii(42);
print "ok\n";'
tests[1431]='BEGIN{package Foo;our $DOT=qr/[.]/;};package main;print "ok\n" if "dot.dot" =~ m/($Foo::DOT)/'
tests[1432]='BEGIN{$DOT=qr/[.]/}print "ok\n" if "dot.dot" =~ m/($DOT)/'
tests[144]='print index("long message\0xx","\0")'
result[144]='12'
tests[145]='my $bits = 0; for (my $i = ~0; $i; $i >>= 1) { ++$bits; }; print $bits'
result[145]=`$PERL -MConfig -e'print 8*$Config{ivsize}'`
tests[146]='my $a = v120.300; my $b = v200.400; $a ^= $b; print sprintf("%vd", $a);'
result[146]='176.188'
tests[148]='open(FH, ">", "ccode148i.tmp"); print FH "1\n"; close FH; print -s "ccode148i.tmp"'
result[148]='2'
tests[149]='format Comment =
ok
.

{
  local $~ = "Comment";
  write;
}'
tests[150]='print NONEXISTENT "foo"; print "ok" if $! == 9'
tests[1501]='$! = 0; print NONEXISTENT "foo"; print "ok" if $! == 9'
tests[152]='print "ok" if find PerlIO::Layer "perlio"'
tests[154]='$SIG{__WARN__} = sub { die "warning: $_[0]" }; opendir(DIR, ".");closedir(DIR);print q(ok)'
tests[156]='use warnings;
no warnings qw(portable);
use XSLoader;
XSLoader::load() if $ENV{force_xsloader}; # trick for perlcc to force xloader to be compiled
{
    my $q = 12345678901;
    my $x = sprintf("%llx", $q);
    print "ok\n" if hex $x == 0x2dfdc1c35;
    exit;
}'
tests[157]='$q = 18446744073709551615;print scalar($q)."\n";print scalar(18446744073709551615)."\n";'
result[157]='18446744073709551615
18446744073709551615'
tests[1571]='my $a = 9223372036854775807; print "ok\n" if ++$a == 9223372036854775808;'
# duplicate of 148
tests[158]='open W, ">ccodetmp" or die "1: $!";print W "foo";close W;open R, "ccodetmp" or die "2: $!";my $e=eof R ? 1 : 0;close R;print "$e\n";'
result[158]='0'
tests[159]='@X::ISA = "Y"; sub Y::z {"Y::z"} print "ok\n" if  X->z eq "Y::z"; delete $X::{z}; exit'
# see 188
tests[160]='sub foo { (shift =~ m?foo?) ? 1 : 0 }
print "ok\n";'
tests[161]='sub PVBM () { foo } { my $dummy = index foo, PVBM } print PVBM'
result[161]='foo'
# duplicate of 142
tests[162]='$x = "\x{1234}"; print "ok\n" if ord($x) == 0x1234;'
tests[163]='# WontFix
my $destroyed = 0;
sub  X::DESTROY { $destroyed = 1 }
{
	my $x;
	BEGIN {$x = sub { }  }
	$x = bless {}, 'X';
}
print qq{ok\n} if $destroyed == 1;'
# duplicate of 148
tests[164]='open(DUPOUT,">&STDOUT");close(STDOUT);open(F,">&DUPOUT");print F "ok\n";'
tests[165]='use warnings;
sub recurse1 {
    unshift @_, "x";
    no warnings "recursion";
    goto &recurse2;
}
sub recurse2 {
    my $x = shift;
    $_[0] ? +1 + recurse1($_[0] - 1) : 0
}
print "ok\n" if recurse1(500) == 500;'
tests[166]='my $ok = 1;
foreach my $chr (60, 200, 600, 6000, 60000) {
  my ($key, $value) = (chr ($chr) . "\x{ABCD}", "$chr\x{ABCD}");
  chop($key, $value);
  my %utf8c = ( $key => $value );
  my $tempval = sprintf q($utf8c{"\x{%x}"}), $chr;
  my $ev = eval $tempval;
  $ok = 0 if !$ev or $ev ne $value;
} print "ok" if $ok'
tests[167]='$a = "a\xFF\x{100}";
eval {$b = crypt($a, "cd")};
print $@;'
result[167]='Wide character in crypt at ccode167.pl line 2.'
tests[168]='my $start_time = time;
eval {
    local $SIG{ALRM} = sub { die "ALARM !\n" };
    alarm 1;
    # perlfunc recommends against using sleep in combination with alarm.
    1 while (time - $start_time < 3);
};
alarm 0;
print $@;
print "ok\n" if $@ eq "ALARM !\n";'
result[168]='ALARM !
ok'
tests[169]='#TODO Attribute::Handlers
package MyTest;
use Attribute::Handlers;
sub Check :ATTR {
    print "called\n";
    print "ok\n" if ref $_[4] eq "ARRAY" && join(",", @{$_[4]}) eq join(",", qw/a b c/);
}
sub a_sub :Check(qw/a b c/) {
    return 42;
}
print a_sub()."\n";'
result[169]='called
ok
42'
tests[170]='eval "sub xyz (\$) : bad ;"; print "~~~~\n$@~~~~\n"'
result[170]='~~~~
Invalid CODE attribute: bad at (eval 1) line 1.
BEGIN failed--compilation aborted at (eval 1) line 1.
~~~~'
tests[172]='package Foo;
use overload q("") => sub { "Foo" };
package main;
my $foo = bless {}, "Foo";
print "ok " if "$foo" eq "Foo";
print "$foo\n";'
result[172]='ok Foo'
tests[173]='# WontFix
use constant BEGIN   => 42; print "ok 1\n" if BEGIN == 42;
use constant INIT   => 42; print "ok 2\n" if INIT == 42;
use constant CHECK   => 42; print "ok 3\n" if CHECK == 42;'
result[173]='Prototype mismatch: sub main::BEGIN () vs none at ./ccode173.pl line 2.
Constant subroutine BEGIN redefined at ./ccode173.pl line 2.
ok 1
ok 2
ok 3'
tests[174]='
my $str = "\x{10000}\x{800}";
no warnings "utf8";
{ use bytes; $str =~ s/\C\C\z//; }
my $ref = "\x{10000}\0";
print "ok 1\n" if ~~$str eq $ref;
$str = "\x{10000}\x{800}";
{ use bytes; $str =~ s/\C\C\z/\0\0\0/; }
my $ref = "\x{10000}\0\0\0\0";
print "ok 2\n" if ~~$str eq $ref;'
result[174]='ok 1
ok 2'
tests[175]='{
  # note that moving the use in an eval block solve the problem
  use warnings NONFATAL => all;
  $SIG{__WARN__} = sub { "ok - expected warning\n" };
  my $x = pack( "I,A", 4, "X" );
  print "ok\n";
}'
result[175]='ok - expected warning
ok'
tests[176]='use Math::BigInt; print Math::BigInt::->new(5000000000);'
result[176]='5000000000'
tests[177]='use version; print "ok\n" if version::is_strict("4.2");'
tests[178]='BEGIN { $hash  = { pi => 3.14, e => 2.72, i => -1 } ;} print scalar keys $hash;'
result[178]='3'
tests[179]='#TODO smartmatch subrefs
{
    package Foo;
    sub new { bless {} }
}
package main;
our $foo = Foo->new;
our $bar = $foor; # required to generate the wrong behavior
my $match = eval q($foo ~~ undef) ? 1 : 0;
print "match ? $match\n";'
result[179]='match ? 0'
tests[180]='use feature "switch"; use integer; given(3.14159265) { when(3) { print "ok\n"; } }'
tests[181]='sub End::DESTROY { $_[0]->() };
my $inx = "OOOO";
$SIG{__WARN__} = sub { print$_[0] . "\n" };
{
    $@ = "XXXX";
    my $e = bless( sub { die $inx }, "End")
}
print q(ok)'
tests[182]='#TODO stash-magic delete renames to ANON
my @c; sub foo { @c = caller(0); print $c[3] } my $fooref = delete $::{foo}; $fooref -> ();'
result[182]='main::__ANON__'
tests[183]='main->import(); print q(ok)'
tests[184]='use warnings;
sub xyz { no warnings "redefine"; *xyz = sub { $a <=> $b }; &xyz }
eval { @b = sort xyz 4,1,3,2 };
print defined $b[0] && $b[0] == 1 && $b[1] == 2 && $b[2] == 3 && $b[3] == 4 ? "ok\n" : "fail\n";
exit;
{
    package Foo;
    use overload (qw("" foo));
}
{
    package Bar;
    no warnings "once";
    sub foo { $ENV{fake} }
}
'
# usage: t/testc.sh -O3 -Dp,-UCarp 185
tests[185]='my $a=pack("U",0xFF);use bytes;print "not " unless $a eq "\xc3\xbf" && bytes::length($a) == 2; print "ok\n";'
tests[186]='eval q/require B/; my $sub = do { package one; \&{"one"}; }; delete $one::{one}; my $x = "boom"; print "ok\n";'
# duplicate of 182
tests[187]='my $glob = \*Phoo::glob; undef %Phoo::; print ( ( "$$glob" eq "*__ANON__::glob" ) ? "ok\n" : "fail with $$glob\n" );'
tests[188]='package aiieee;sub zlopp {(shift =~ m?zlopp?) ? 1 : 0;} sub reset_zlopp {reset;}
package main; print aiieee::zlopp(""), aiieee::zlopp("zlopp"), aiieee::zlopp(""), aiieee::zlopp("zlopp");
aiieee::reset_zlopp(); print aiieee::zlopp("zlopp")'
result[188]='01001'
tests[191]='# WontFix
BEGIN{sub plan{42}} {package Foo::Bar;} print((exists $Foo::{"Bar::"} && $Foo::{"Bar::"} eq "*Foo::Bar::") ? "ok\n":"bad\n"); plan(fake=>0);'
tests[192]='use warnings;
{
 no warnings qw "once void";
 my %h; # We pass a key of this hash to the subroutine to get a PVLV.
 sub { for(shift) {
  # Set up our glob-as-PVLV
  $_ = *hon;
  # Assigning undef to the glob should not overwrite it...
  {
   my $w;
   local $SIG{__WARN__} = sub { $w = shift };
   *$_ = undef;
   print ( $w =~ m/Undefined value assigned to typeglob/ ? "ok" : "not ok");
  }
 }}->($h{k});
}'
tests[193]='unlink q{not.a.file}; $! = 0; open($FOO, q{not.a.file}); print( $! ne 0 ? "ok" : q{error: $! should not be 0}."\n"); close $FOO;'
tests[194]='$0 = q{ccdave with long name}; #print "pid: $$\n";
$s=`ps w | grep "$$" | grep "[c]cdave"`;
print ($s =~ /ccdave with long name/ ? q(ok) : $s);'
tests[1941]='$0 = q{ccdave}; #print "pid: $$\n";
$s=`ps auxw | grep "$$" | grep "ccdave"|grep -v grep`;
print q(ok) if $s =~ /ccdave/'
# duplicate of 152
tests[195]='use PerlIO;  eval { require PerlIO::scalar }; find PerlIO::Layer "scalar"; print q(ok)'
tests[196]='package Foo;
sub new { bless {}, shift }
DESTROY { $_[0] = "foo" }
package main;
eval q{\\($x, $y, $z) = (1, 2, 3);};
my $m;
$SIG{__DIE__} = sub { $m = shift };
{ my $f = Foo->new }
print "m: $m\n";'
result[196]='m: Modification of a read-only value attempted at ccode196.pl line 3.'
tests[197]='package FINALE;
{
    $ref3 = bless ["ok - package destruction"];
    my $ref2 = bless ["ok - lexical destruction\n"];
    local $ref1 = bless ["ok - dynamic destruction\n"];
    1;
}
DESTROY {
    print $_[0][0];
}'
result[197]='ok - dynamic destruction
ok - lexical destruction
ok - package destruction'
# duplicate of 150
tests[198]='{
  open(my $NIL, qq{|/bin/echo 23}) or die "fork failed: $!";
  $! = 1;
  close $NIL;
  if($! == 5) { print}
}'
result[198]='23'
# duplicate of 90
tests[199]='"abc" =~ /(.)./; print @+; print "end\n"'
result[199]='21end'
tests[200]='%u=("\x{123}"=>"fo"); print "ok" if $u{"\x{123}"} eq "fo"'
tests[2001]='BEGIN{%u=("\x{123}"=>"fo");} print "ok" if $u{"\x{123}"} eq "fo";'
tests[201]='use Storable;*Storable::CAN_FLOCK=sub{1};print qq{ok\n}'
tests[2011]='sub can {require Config; import Config;return $Config{d_flock}}
use IO::File;
can();
print "ok\n";'
tests[203]='#TODO perlio layers
use open(IN => ":crlf", OUT => ":encoding(cp1252)");
open F, "<", "/dev/null";
my %l = map {$_=>1} PerlIO::get_layers(F, input  => 1);
print $l{crlf} ? q(ok) : keys(%l);'
# issue 29
tests[2900]='use open qw(:std :utf8);
BEGIN{ `echo ö > xx.bak`; }
open X, "xx.bak";
$_ = <X>;
print unpack("U*", $_), " ";
print $_ if /\w/;'
result[2900]='24610 ö'
tests[207]='use warnings;
sub asub { }
asub(tests => 48);
my $str = q{0};
$str =~ /^[ET1]/i;
{
    no warnings qw<io deprecated>;
    print "ok 1\n" if opendir(H, "t");
    print "ok 2" if open(H, "<", "TESTS");
}'
result[207]='ok 1
ok 2'
tests[208]='sub MyKooh::DESTROY { print "${^GLOBAL_PHASE} MyKooh " }  my $my =bless {}, MyKooh;
sub OurKooh::DESTROY { print "${^GLOBAL_PHASE} OurKooh" }our $our=bless {}, OurKooh;'
if [[ `$PERL -e'print (($] < 5.014)?0:1)'` -gt 0 ]]; then
  result[208]='RUN MyKooh DESTRUCT OurKooh'
else
  result[208]=' MyKooh  OurKooh'
fi
tests[210]='$a = 123;
package xyz;
sub xsub {bless [];}
$x1 = 1; $x2 = 2;
$s = join(":", sort(keys %xyz::));
package abc;
my $foo;
print $xyz::s'
result[210]='s:x1:x2:xsub'
tests[212]='$blurfl = 123;
{
    package abc;
    $blurfl = 5;
}
$abc = join(":", sort(keys %abc::));
package abc;
print "variable: $blurfl\n";
print "eval: ". eval q/"$blurfl\n"/;
package main;
sub ok { 1 }'
result[212]='variable: 5
eval: 5'
tests[214]='
my $expected = "foo";
sub check(_) { print( (shift eq $expected) ? "ok\n" : "not ok\n" ) }
$_ = $expected;
check;
undef $expected;
&check; # $_ not passed'
result[214]='ok
ok'
tests[215]='eval { $@ = "t1\n"; do { die "t3\n" }; 1; }; print ":$@:\n";'
result[215]=':t3
:'
tests[216]='eval { $::{q{@}}=42; }; print qq{ok\n}'
# multideref, also now a 29
tests[219]='my (%b,%h); BEGIN { %b=(1..8);@a=(1,2,3,4); %h=(1=>2,3=>4) } $i=0; my $l=-1; print $h->{$b->{3}},$h->{$a[-1]},$a[$i],$a[$l],$h{3}'
result[219]='144'
# also at 904
tests[220]='
my $content = "ok\n";
while ( $content =~ m{\w}g ) {
    $_ .= "$-[0]$+[0]";
}
print "ok" if $_ eq "0112";'
tests[223]='use strict; eval q({ $x = sub }); print $@'
result[223]='Illegal declaration of anonymous subroutine at (eval 1) line 1.'
tests[224]='use bytes; my $p = "\xB6"; my $u = "\x{100}"; my $pu = "\xB6\x{100}"; print ( $p.$u eq $pu ? "ko\n" : "ok\n" );'
tests[225]='$_ = $dx = "\x{10f2}"; s/($dx)/$dx$1/; $ok = 1 if $_ eq "$dx$dx"; $_ = $dx = "\x{10f2}"; print qq{end\n};'
result[225]='end'
tests[226]='# WontFix
@INC = (); dbmopen(%H, $file, 0666)'
result[226]='No dbm on this machine at -e line 1.'
tests[227]='open IN, "/dev/null" or die $!; *ARGV = *IN; foreach my $x (<>) { print $x; } close IN; print qq{ok\n}'
tests[229]='sub yyy () { "yyy" } print "ok\n" if( eval q{yyy} eq "yyy");'
#issue 30
tests[230]='sub f1 { my($self) = @_; $self->f2;} sub f2 {} sub new {} print "@ARGV\n";'
result[230]=' '
tests[232]='use Carp (); exit unless Carp::longmess(); print qq{ok\n}'
tests[234]='$c = 0; for ("-3" .. "0") { $c++ } ; print "$c"'
result[234]='4'
# t/testc.sh -O3 -Dp,-UCarp,-v 235
tests[235]='BEGIN{$INC{"Carp.pm"}="/dev/null"} $d = pack("U*", 0xe3, 0x81, 0xAF); { use bytes; $ol = bytes::length($d) } print $ol'
result[235]='6'
# -O3
tests[236]='sub t { if ($_[0] == $_[1]) { print "ok\n"; } else { print "not ok - $_[0] == $_[1]\n"; } } t(-1.2, " -1.2");'
tests[237]='print "\000\000\000\000_"'
result[237]='_'
tests[238]='sub f ($);
sub f ($) {
  my $test = $_[0];
  write;
  format STDOUT =
ok @<<<<<<<
$test
.
}
f("");
'
tests[239]='my $x="1";
format STDOUT =
ok @<<<<<<<
$x
.
write;print "\n";'
result[239]='ok 1'
tests[240]='my $a = "\x{100}\x{101}Aa";
print "ok\n" if "\U$a" eq "\x{100}\x{100}AA";
my $b = "\U\x{149}cD"; # no pb without that line'
tests[241]='package Pickup; use UNIVERSAL qw( can ); if (can( "Pickup", "can" ) != \&UNIVERSAL::can) { print "not " } print "ok\n";'
tests[242]='$xyz = ucfirst("\x{3C2}");
$a = "\x{3c3}foo.bar";
($c = $a) =~ s/(\p{IsWord}+)/ucfirst($1)/ge;
print "ok\n" if $c eq "\x{3a3}foo.Bar";'
tests[243]='use warnings "deprecated"; print hex(${^WARNINGS}) . " "; print hex(${^H})'
result[243]='0 598'
tests[244]='print "($_)\n" for q{-2}..undef;'
result[244]='(-2)
(-1)
(0)'
tests[245]='sub foo {
    my ( $a, $b ) = @_;
    print "a: ".ord($a)." ; b: ".ord($b)." [ from foo ]\n";
}
print "a: ". ord(lc("\x{1E9E}"))." ; ";
print "b: ". ord("\x{df}")."\n";
foo(lc("\x{1E9E}"), "\x{df}");'
result[245]='a: 223 ; b: 223
a: 223 ; b: 223 [ from foo ]'
# see t/issue235.t test 2
tests[246]='sub foo($\@); eval q/foo "s"/; print $@'
result[246]='Not enough arguments for main::foo at (eval 1) line 1, at EOF'
tests[247]='# WontFix
no warnings; $[ = 1; $big = "N\xabN\xab"; print qq{ok\n} if rindex($big, "N", 3) == 3'
tests[248]='#WONTFIX lexical $_ in re-eval
{my $s="toto";my $_="titi";{$s =~ /to(?{ print "-$_-$s-\n";})to/;}}'
result[248]='-titi-toto-'
tests[249]='#TODO version
use version; print version::is_strict(q{01}) ? 1 : 0'
result[249]='0'
tests[250]='#TODO version
use warnings qw/syntax/; use version; $withversion::VERSION = undef; eval q/package withversion 1.1_;/; print $@;'
result[250]='Misplaced _ in number at (eval 1) line 1.
Invalid version format (no underscores) at (eval 1) line 1, near "package withversion "
syntax error at (eval 1) line 1, near "package withversion 1.1_"'
tests[251]='sub f;print "ok" if exists &f'
tests[2511]='#TODO 5.18
sub f :lvalue;print "ok" if exists &f'
tests[2512]='sub f ();print "ok" if exists &f'
tests[2513]='sub f ($);print "ok" if exists &f'
tests[2514]='sub f;print "ok" if exists &f'
# duplicate of 234
tests[252]='my $i = 0; for ("-3".."0") { ++$i } print $i'
result[252]='4'
tests[253]='INIT{require "t/test.pl"}plan(tests=>2);is("\x{2665}", v9829);is(v9829,"\x{2665}");'
result[253]='1..2
ok 1
ok 2'
tests[254]='#TODO destroy upgraded lexvar
my $flag = 0;
sub  X::DESTROY { $flag = 1 }
{
  my $x;              # x only exists in that scope
  BEGIN { $x = 42 }   # pre-initialized as IV
  $x = bless {}, "X"; # run-time upgrade and bless to call DESTROY
  # undef($x);        # value should be free when exiting scope
}
print "ok\n" if $flag;'
# duplicate of 185, bytes_heavy
tests[255]='$a = chr(300);
my $l = length($a);
my $lb;
{ use bytes; $lb = length($a); }
print( ( $l == 1 && $lb == 2 ) ? "ok\n" : "l -> $l ; lb -> $lb\n" );'
tests[256]='BEGIN{ $| = 1; } print "ok\n" if $| == 1'
tests[2561]='BEGIN{ $/ = "1"; } print "ok\n" if $/ == "1"'
tests[259]='use JSON::XS; print encode_json([\0])'
result[259]='[false]'
tests[260]='sub FETCH_SCALAR_ATTRIBUTES {''} sub MODIFY_SCALAR_ATTRIBUTES {''}; my $a :x=1; print $a'
result[260]='1'
tests[261]='q(12-feb-2015) =~ m#(\d\d?)([\-\./])(feb|jan)(?:\2(\d\d+))?#; print $4'
result[261]='2015'
tests[262]='use POSIX'
result[262]=' '
tests[263]='use JSON::XS; print encode_json []'
result[263]='[]'
tests[264]='no warnings; warn "$a.\n"'
result[264]='.'
tests[272]='$d{""} = qq{ok\n}; print $d{""};'
tests[2721]='BEGIN{$d{""} = qq{ok\n};} print $d{""};'
tests[273]='package Foo; use overload; sub import { overload::constant "integer" => sub { return shift }}; package main; BEGIN { $INC{"Foo.pm"} = "/lib/Foo.pm" }; use Foo; my $result = eval "5+6"; print "$result\n"'
result[273]='11'
tests[274]='package Foo;

sub match { shift =~ m?xyz? ? 1 : 0; }
sub match_reset { reset; }

package Bar;

sub match { shift =~ m?xyz? ? 1 : 0; }
sub match_reset { reset; }

package main;
print "1..5\n";

print "ok 1\n" if Bar::match("xyz");
print "ok 2\n" unless Bar::match("xyz");
print "ok 3\n" if Foo::match("xyz");
print "ok 4\n" unless Foo::match("xyz");

Foo::match_reset();
print "ok 5\n" if Foo::match("xyz");'
result[274]='1..5
ok 1
ok 2
ok 3
ok 4
ok 5'
tests[277]='format OUT =
bar ~~
.
open(OUT, ">/dev/null"); write(OUT); close OUT; print q(ok)'
tests[280]='package M; $| = 1; sub DESTROY {eval {print "Farewell ",ref($_[0])};} package main; bless \$A::B, q{M}; *A:: = \*B::;'
result[280]='Farewell M'
tests[281]='"I like pie" =~ /(I) (like) (pie)/; "@-" eq  "0 0 2 7" and print "ok\n"; print "\@- = @-\n\@+ = @+\nlen \@- = ",scalar @-'
result[281]='ok
@- = 0 0 2 7
@+ = 10 1 6 10
len @- = 4'
tests[282]='use vars qw($glook $smek $foof); $glook = 3; $smek = 4; $foof = "halt and cool down"; my $rv = \*smek; *glook = $rv; my $pv = ""; $pv = \*smek; *foof = $pv; print "ok\n";'
tests[283]='#238 Undefined format "STDOUT"
format =
ok
.
write'
tests[284]='#-O3 only
my $x="123456789";
format OUT =
^<<~~
$x
.
open OUT, ">ccode.tmp";
write(OUT);
close(OUT);
print `cat "ccode.tmp"`'
result[284]='123
456
789'
tests[289]='no warnings; sub z_zwap (&); print qq{ok\n} if eval q{sub z_zwap {return @_}; 1;}'
tests[290]='sub f;print "ok" if exists &f && not defined &f;'
tests[293]='use Coro; print q(ok)'
tests[295]='"zzaaabbb" =~ m/(a+)(b+)/ and print "@- : @+\n"'
result[295]='2 2 5 : 8 5 8'
tests[299]='#TODO version
package Pickup; use UNIVERSAL qw( VERSION ); print qq{ok\n} if VERSION "UNIVERSAL";'
tests[300]='use mro;print @{mro::get_linear_isa("mro")};'
result[300]='mro'
tests[301]='{ package A; use mro "c3";  sub foo { "A::foo" } } { package B; use base "A"; use mro "c3"; sub foo { (shift)->next::method() } } print qq{ok\n} if B->foo eq "A::foo";'
tests[305]='use constant ASCII => eval { require Encode; Encode::find_encoding("ascii"); } || 0; print ASCII->encode("www.google.com")'
result[305]='www.google.com'
tests[3051]='INIT{ sub ASCII { eval { require Encode; Encode::find_encoding("ASCII"); } || 0; }} print ASCII->encode("www.google.com")'
result[3051]='www.google.com'
tests[3052]='use Net::DNS::Resolver; my $res = Net::DNS::Resolver->new; $res->send("www.google.com"), print q(ok)'
tests[365]='use constant JP => eval { require Encode; Encode::find_encoding("euc-jp"); } || 0; print JP->encode("www.google.com")'
result[365]='www.google.com'
tests[306]='package foo; sub check_dol_slash { print ($/ eq "\n" ? "ok" : "not ok") ; print  "\n"} sub begin_local { local $/;} ; package main; BEGIN { foo::begin_local() }  foo::check_dol_slash();'
tests[308]='print (eval q{require Net::SSLeay;} ? qq{ok\n} : $@);'
tests[309]='print $_,": ",(eval q{require }.$_.q{;} ? qq{ok\n} : $@) for qw(Net::LibIDN Net::SSLeay);'
result[309]='Net::LibIDN: ok
Net::SSLeay: ok'
tests[310]='package foo;
sub dada { my $line = <DATA> }
print dada;
__DATA__
ok
b
c
'
tests[312]='require Scalar::Util; eval "require List::Util"; print "ok"'
tests[314]='open FOO, ">", "ccode314.tmp"; print FOO "abc"; close FOO; open FOO, "<", "ccode314.tmp"; { local $/="b"; $in=<FOO>; if ($in eq "ab") { print "ok\n" } else { print qq(separator: "$/"\n\$/ is "$/"\nFAIL: "$in"\n)}}; unlink "ccode314.tmp"'
tests[3141]='open FOO, ">", "ccode3141.tmp"; print FOO "abc"; close FOO; open FOO, "<", "ccode3141.tmp"; { $/="b"; $in=<FOO>; if ($in eq "ab") { print "ok\n" } else { print qq(separator: "$/"\n\$/ is "$/"\nFAIL: "$in"\n)}}; unlink "ccode3141.tmp"'
tests[316]='
package Diamond_A; sub foo {};
package Diamond_B; use base "Diamond_A";
package Diamond_C; use base "Diamond_A";
package Diamond_D; use base ("Diamond_B", "Diamond_C"); use mro "c3";
package main; my $order = mro::get_linear_isa("Diamond_D");
              print $order->[3] eq "Diamond_A" ? "ok" : "not ok"; print "\n"'
tests[317]='use Net::SSLeay();use IO::Socket::SSL();Net::SSLeay::OpenSSL_add_ssl_algorithms(); my $ssl_ctx = IO::Socket::SSL::SSL_Context->new(SSL_server => 1); print q(ok)'
tests[318]='{ local $\ = "ok" ; print "" }'
tests[319]='#TODO Wide character warnings missing (bytes layer ignored)
use warnings q{utf8}; my $w; local $SIG{__WARN__} = sub { $w = $_[0] }; my $c = chr(300); open F, ">", "a"; binmode(F, ":bytes:"); print F $c,"\n"; close F; print $w'
tests[320]='#TODO No warnings reading in invalid utf8 stream (utf8 layer ignored)
use warnings "utf8"; local $SIG{__WARN__} = sub { $@ = shift }; open F, ">", "a"; binmode F; my ($chrE4, $chrF6) = (chr(0xE4), chr(0xF6)); print F "foo", $chrE4, "\n"; print F "foo", $chrF6, "\n"; close F; open F, "<:utf8", "a";  undef $@; my $line = <F>; print q(ok) if $@ =~ /utf8 "\xE4" does not map to Unicode/;'
tests[324]='package Master;
use mro "c3";
sub me { "Master" }
package Slave;
use mro "c3";
use base "Master";
sub me { "Slave of ".(shift)->next::method }
package main;
print Master->me()."\n";
print Slave->me()."\n";
'
result[324]='Master
Slave of Master'
tests[326]='#TODO method const maybe::next::method
package Diamond_C; sub maybe { "Diamond_C::maybe" } package Diamond_D; use base "Diamond_C"; use mro "c3"; sub maybe { "Diamond_D::maybe => " . ((shift)->maybe::next::method() || 0) } package main; print "ok\n" if Diamond_D->maybe;'
tests[328]='#WONTFIX re-eval lex/global mixup
my $code = q[{$blah = 45}]; our $blah = 12; eval "/(?$code)/"; print "$blah\n"'
result[328]=45
tests[329]='#WONTFIX re-eval lex/global mixup
$_ = q{aaa}; my @res; pos = 1; s/\Ga(?{push @res, $_, $`})/xx/g; print "ok\n" if "$_ @res" eq "axxxx aaa a aaa aa"; print "$_ @res\n"'
result[329]='ok
axxxx aaa a aaa aa'
tests[330]='"\x{101}a" =~ qr/\x{100}/i && print "ok\n"'
tests[331]='use 5.010; use charnames ":full"; my $char = q/\N{LATIN CAPITAL LETTER A WITH MACRON}/; my $a = eval qq ["$char"]; print length($a) == 1 ? "ok\n" : "$a\n".length($a)."\n"'
tests[332]='#TODO re-eval no_modify, probably WONTFIX
use re "eval"; our ( $x, $y, $z ) = 1..3; $x =~ qr/$x(?{ $y = $z++ })/; undef $@; print "ok\n"'
tests[333]='use encoding "utf8";
my @hiragana =  map {chr} ord("ぁ")..ord("ん"); my @katakana =  map {chr} ord("ァ")..ord("ン"); my $hiragana = join(q{} => @hiragana); my $katakana = join(q{} => @katakana); my %h2k; @h2k{@hiragana} = @katakana; $str = $hiragana; $str =~ s/([ぁ-ん])/$h2k{$1}/go; print $str eq $katakana ? "ok\n" : "not ok\n$hiragana\n$katakana\n";'
tests[338]='use utf8; my $l = "ñ"; my $re = qr/ñ/; print $l =~ $re ? qq{ok\n} : length($l)."\n".ord($l)."\n";'
tests[340]='eval q/use Net::DNS/; my $new = "IO::Socket::INET6"->can("new") or die "die at new"; my $inet = $new->("IO::Socket::INET6", LocalAddr => q/localhost/, Proto => "udp", LocalPort => undef); print q(ok) if ref($inet) eq "IO::Socket::INET6";'
# used to fail in the inc-i340 branches CORE/base/lex.t 54
tests[3401]='sub foo::::::bar { print "ok\n"; } foo::::::bar;'
# wontfix on -O3: static string *end for "main::bar"
tests[345]='eval q/use Sub::Name; 1/ or die "no Sub::Name"; subname("main::bar", sub { 42 } ); print "ok\n";'
# those work fine:
tests[3451]='eval q/use Sub::Name; 1/ or die "no Sub::Name"; subname("bar", sub { 42 } ); print "ok\n";'
tests[3452]='eval q/use Sub::Name; 1/ or die "no Sub::Name"; $bar="main::bar"; subname($bar, sub { 42 } ); print "ok\n";'
tests[348]='package Foo::Bar; sub baz { 1 }
package Foo; sub new { bless {}, shift } sub method { print "ok\n"; }
package main; Foo::Bar::baz();
my $foo = sub {
  Foo->new
}->();
$foo->method;'
tests[350]='package Foo::Moose; use Moose; has bar => (is => "rw", isa => "Int"); 
package main; my $moose = Foo::Moose->new; print "ok" if 32 == $moose->bar(32);'
tests[368]='use EV; print q(ok)'
tests[369]='
use EV;
use Coro;
use Coro::Timer;
my @a;
push @a, async {
  while() {
    warn $c++;
    Coro::Timer::sleep 1;
  };
};
push @a, async {
  while() {
    warn $d++;
    Coro::Timer::sleep 0.5;
  };
};
schedule;
print q(ok)'
tests[371]='package foo;use Moose;
has "x" => (isa => "Int", is => "rw", required => 1);
has "y" => (isa => "Int", is => "rw", required => 1);
sub clear { my $self = shift; $self->x(0); $self->y(0); }
__PACKAGE__->meta->make_immutable;
package main;
my $f = foo->new( x => 5, y => 6);
print $f->x . "\n";'
result[371]='5'
if [[ $v518 -gt 0 ]]; then
  tests[372]='use utf8; require mro; my $f_gen = mro::get_pkg_gen("ᕘ"); undef %ᕘ::; mro::get_pkg_gen("ᕘ"); delete $::{"ᕘ::"}; print "ok";'
  result[372]='ok'
fi
tests[2050]='use utf8;package 텟ţ::ᴼ; sub ᴼ_or_Ḋ { "ok" } print ᴼ_or_Ḋ;'
result[2050]='ok'
tests[2051]='use utf8;package ƂƂƂƂ; sub ƟK { "ok" } package ƦƦƦƦ; use base "ƂƂƂƂ"; my $x = bless {}, "ƦƦƦƦ"; print $x->ƟK();'
result[2051]='ok'

init

while getopts "qsScohv" opt
do
  if [ "$opt" = "q" ]; then
      Q=1
      OCMD="$QOCMD"
      qq="-qq,"
      if [ "$VERS" = "5.6.2" ]; then QOCMD=$OCMD; qq=""; fi
  fi
  if [ "$opt" = "v" ]; then
      Q=
      QOCMD="$OCMD"
      qq=""
  fi
  if [ "$opt" = "s" ]; then SKIP=1; fi
  if [ "$opt" = "o" ]; then Mblib=" "; SKIP=1; SKI=1; init; fi
  if [ "$opt" = "S" ]; then SKIP=1; SKI=1; fi
  if [ "$opt" = "c" ]; then CONT=1; shift; fi
  if [ "$opt" = "h" ]; then help; exit; fi
done

if [ -z "$Q" ]; then
    make
else
    make -s >/dev/null
fi

# need to shift the options
while [ -n "$1" -a "${1:0:1}" = "-" ]; do shift; done

if [ -n "$1" ]; then
  while [ -n "$1" ]; do
    btest $1
    shift
  done
else
  for b in $(seq $ntests); do
    btest $b
  done
fi

# 5.8: all PASS
# 5.10: FAIL: 2-5, 7, 11, 15. With -D 9-12 fail also.
# 5.11: FAIL: 2-5, 7, 11, 15-16 (all segfaulting in REGEX). With -D 9-12 fail also.
# 5.11d: WRONG 4, FAIL: 9-11, 15-16
# 5.11d linux: WRONG 4, FAIL: 11, 16

#only if ByteLoader installed in @INC
if false; then
echo ${OCMD}-H,-obytecode2.plc bytecode2.pl
${OCMD}-H,-obytecode2.plc bytecode2.pl
chmod +x bytecode2.plc
echo ./bytecode2.plc
./bytecode2.plc
fi

# package pmc
if false; then
echo "package MY::Test;" > bytecode1.pm
echo "print 'hi'" >> bytecode1.pm
echo ${OCMD}-m,-obytecode1.pmc bytecode1.pm
${OCMD}-obytecode1.pmc bytecode1.pm
fi
