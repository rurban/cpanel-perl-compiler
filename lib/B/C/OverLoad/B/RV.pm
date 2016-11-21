package B::RV;

use strict;

use B::C::Config;
use B::C::File qw/svsect init init2/;
use B::C::Helpers qw/is_constant/;

use B::C::Helpers::Symtable qw/objsym savesym/;

# Since 5.11 also called by IV::save (SV -> IV)
sub do_save {
    my ( $sv, $fullname ) = @_;

    debug(
        sv => "Saving RV %s (0x%x) - called from %s:%s\n",
        ref($sv), $$sv, @{ [ ( caller(1) )[3] ] }, @{ [ ( caller(1) )[2] ] }
    );

    my $rv = save_op( $sv, $fullname );
    return '0' unless $rv;

    svsect()->comment("any, refcnt, flags, sv_u");

    # 5.22 has a wrong RV->FLAGS (https://github.com/perl11/cperl/issues/63)
    my $flags = $sv->FLAGS;
    $flags = 0x801 if $flags & 9;    # not a GV but a ROK IV (21)

    # 5.10 has no struct xrv anymore, just sv_u.svu_rv. static or dynamic?
    # initializer element is computable at load time
    my $ix = svsect()->sadd(
        "ptr_undef, %Lu, 0x%x, {%s}", $sv->REFCNT, $flags,
        ( is_constant($rv) ? ".svu_rv=$rv" : "0 /* $rv */" )
    );

    svsect()->debug( $fullname, $sv );
    my $s = "sv_list[" . $ix . "]";

    init()->sadd( "%s.sv_any = (void*)&%s - sizeof(void*);", $s, $s );    # 354 defined needs SvANY
    if ( !is_constant($rv) ) {
        if ( $rv =~ /get_cv/ ) {                                          # ref($rv) ne 'B::GV' && ref($rv) ne 'B::HV'
            init2()->sadd( "%s.sv_u.svu_rv = (SV*)%s;", $s, $rv );
        }
        else {
            init()->sadd( "%s.sv_u.svu_rv = (SV*)%s;", $s, $rv );
        }
    }

    return "&" . $s;
}

# the save methods should probably be renamed visit
sub save_op {                                                             # previously known as 'sub save_rv'
    my ( $sv, $fullname ) = @_;

    $fullname ||= '(unknown)';

    my $rv = $sv->RV->save($fullname);
    $rv =~ s/^\(([AGHS]V|IO)\s*\*\)\s*(\&sv_list.*)$/$2/;

    return $rv;
}

1;
