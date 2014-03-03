%{!?perl_prefix: %define perl_prefix %(eval "`%{__perl} -V:installprefix`"; echo $installprefix)}
%{!?perl_style: %define perl_style %(eval "`%{__perl} -V:installstyle`"; echo $installstyle)}

%define disttag pSPS

Name:           perl-Class-Fields
Version:        0.203
Release:        3.%{disttag}
Summary:        Inspect the fields of a class
License:        CHECK(GPL+ or Artistic)
Group:          Development/Libraries
URL:            http://search.cpan.org/dist/Class-Fields/
Source0:        http://www.cpan.org/modules/by-module/Class/Class-Fields-%{version}.tar.gz
BuildRoot:      %{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:      noarch
Requires:       perl(base) >= 2
Requires:       perl(Carp)
Requires:       perl(Carp::Assert)
Requires:       perl(constant)
Requires:       perl(Test::More) >= 0.47
Requires:       coreutils

BuildRequires:       perl(Carp::Assert)
BuildRequires:       perl(Test::More) >= 0.47
BuildRequires:  perl(ExtUtils::MakeMaker)
Requires:  perl(:MODULE_COMPAT_%(eval "`%{__perl} -V:version`"; echo $version))

%description
A collection of utility functions/methods for examining the data members of
a class. It provides a nice, high-level interface that should stand the
test of time and Perl upgrades nicely.

%prep
%setup -q -n Class-Fields-%{version}

%build
%{__perl} Makefile.PL INSTALLDIRS=vendor
make %{?_smp_mflags}

%install
%{__rm} -rf $RPM_BUILD_ROOT

make pure_install PERL_INSTALL_ROOT=$RPM_BUILD_ROOT

find $RPM_BUILD_ROOT -type f -name .packlist -exec rm -f {} \;
find $RPM_BUILD_ROOT -depth -type d -exec rmdir {} 2>/dev/null \;

%{_fixperms} $RPM_BUILD_ROOT/*

%check || :
make test

%clean
rm -rf $RPM_BUILD_ROOT

%files
%defattr(-,root,root,-)
%doc Changes
%{perl_vendorlib}/*
%{_mandir}/man3/*.3*

%post

%changelog
* Sun Aug 15 2010 Tom Throckmorton <throck@mcnc.org> = 0.203-3
- spec adjustments to enable rebuild via mock

* Mon Jun 7 2010 Aaron Brown 0.203-2
- Remove the custom %post scripts

* Thu Aug 13 2009 Jason Zurawski 0.203-1
- Specfile autogenerated by cpanspec 1.78.