#!perl

#   !!!!!!!   DO NOT EDIT THIS FILE   !!!!!!!
#   This file is generated by write_buildcustomize.pl.
#   Any changes made here will be lost!

# We are miniperl, building extensions
# Replace the first entry of @INC ("lib") with the list of
# directories we need.
splice(@INC, 0, 1, q /root/rpmbuild/BUILD/perl-5.24.1/cpan/AutoLoader/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/dist/Carp/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/dist/PathTools ,
        q /root/rpmbuild/BUILD/perl-5.24.1/dist/PathTools/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/cpan/ExtUtils-Install/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/cpan/ExtUtils-MakeMaker/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/cpan/ExtUtils-Manifest/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/cpan/File-Path/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/ext/re ,
        q /root/rpmbuild/BUILD/perl-5.24.1/dist/Term-ReadLine/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/dist/Exporter/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/ext/File-Find/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/cpan/Text-Tabs/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/dist/constant/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/cpan/version/lib ,
        q /root/rpmbuild/BUILD/perl-5.24.1/lib );
$^O = 'linux';
__END__
