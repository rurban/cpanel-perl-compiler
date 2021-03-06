package B::SVOP;

use strict;

use B::C::File qw/svopsect init/;
use B::C::Config;
use B::C::Helpers qw/do_labels/;

sub do_save {
    my ( $op, $level, $fullname ) = @_;

    my $svsym = 'Nullsv';

    # XXX moose1 crash with 5.8.5-nt, Cwd::_perl_abs_path also
    if ( $op->name eq 'aelemfast' and $op->flags & 128 ) {    #OPf_SPECIAL
        $svsym = '&PL_sv_undef';                              # pad does not need to be saved
        debug( sv => "SVOP->sv aelemfast pad %d\n", $op->flags );
    }
    elsif ( $op->name eq 'gv'
        and $op->next
        and $op->next->name eq 'rv2cv'
        and $op->next->next
        and $op->next->next->name eq 'defined' ) {

        # 96 do not save a gvsv->cv if just checked for defined'ness
        my $gv   = $op->sv;
        my $gvsv = B::C::svop_name($op);
        if ( $gvsv !~ /^DynaLoader::/ ) {
            debug( gv => "skip saving defined(&$gvsv)" );    # defer to run-time
            $svsym = '(SV*)' . $gv->save(8);                 # ~Save_CV in B::GV::save
        }
        else {
            $svsym = '(SV*)' . $gv->save();
        }
    }
    else {
        my $sv = $op->sv;
        $svsym = $sv->save( "svop " . $op->name );
        if ( $svsym =~ /^(gv_|PL_.*gv)/ ) {
            $svsym = '(SV*)' . $svsym;
        }
        elsif ( $svsym =~ /^\([SAHC]V\*\)\&sv_list/ ) {
            $svsym =~ s/^\([SAHC]V\*\)//;
        }
        else {
            $svsym =~ s/^\([GAPH]V\*\)/(SV*)/;
        }

        WARN( "Error: SVOP: " . $op->name . " $sv $svsym" ) if $svsym =~ /^\(SV\*\)lexwarn/;    #322
    }
    if ( $op->name eq 'method_named' ) {
        my $cv = B::C::method_named( B::C::svop_or_padop_pv($op), B::C::nextcop($op) );
        $cv->save if $cv;
    }
    my $is_const_addr = $svsym =~ m/Null|\&/;

    svopsect()->comment_common("sv");
    my $svop_sv = ( $is_const_addr ? $svsym : "Nullsv /* $svsym */" );
    my $ix = svopsect()->sadd( "%s, (SV*) %s", $op->_save_common, $svop_sv );
    svopsect()->debug( $op->name, $op );
    init()->add("svop_list[$ix].op_sv = (SV*) $svsym;") unless $is_const_addr;

    return "(OP*)&svop_list[$ix]";
}

sub svimmortal {
    my $sym = shift;
    if ( $sym =~ /\(SV\*\)?\&PL_sv_(yes|no|undef|placeholder)/ ) {
        return 1;
    }
    return undef;
}

1;
