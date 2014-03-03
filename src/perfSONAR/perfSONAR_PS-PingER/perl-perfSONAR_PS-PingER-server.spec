%define install_base /opt/perfsonar_ps/PingER
%define logging_base /var/log/perfsonar

# init scripts must be located in the 'scripts' directory
%define init_script_1 PingER

%define disttag pSPS
%define relnum 2 

Name:			perl-perfSONAR_PS-PingER-server
Version:		3.3
Release:		%{relnum}.%{disttag}
Summary:		perfSONAR_PS PingER  Measurement Archive and Collection System
License:		Distributable, see LICENSE
Group:			Development/Libraries
URL:			http://psps.perfsonar.net/pinger/
Source0:		perfSONAR_PS-PingER-server-%{version}.%{relnum}.tar.gz
BuildRoot:		%{_tmppath}/%{name}-%{version}-%{release}-root-%(%{__id_u} -n)
BuildArch:		noarch
Requires:		perl
Requires:		perl(DateTime) >= 0.41
Requires:		perl(DateTime::Format::Builder) >= 0.7901
Requires:		perl(Carp) >= 0.41
Requires:		perl(Carp::Clan) >= 0.41
Requires:		perl(Config::General)
Requires:		perl(Class::Accessor)
Requires:		perl(Class::Fields)
Requires:		perl(aliased) >= 0
Requires:		perl(Cwd)
Requires:		perl(DBI)
Requires:		perl(DB_File)
Requires:		perl(Data::UUID)
Requires:		perl(Date::Manip)
Requires:		perl(Digest::MD5)
Requires:		perl(English)
Requires:		perl(Error)
Requires:		perl(Exporter)
Requires:		perl(Fcntl)
Requires:		perl(File::Basename)
Requires:		perl(File::Path)
Requires:		perl(File::Temp)
Requires:		perl(File::Copy)
Requires:		perl(FileHandle)
Requires:		perl(FindBin)
Requires:		perl(Getopt::Long)
Requires:		perl(Getopt::Std)
Requires:		perl(HTTP::Daemon)
Requires:		perl(Hash::Merge)
Requires:		perl(IO::File)
Requires:		perl(IO::Interface)
Requires:		perl(IO::Socket)
Requires:		perl(Log::Log4perl) >= 1
Requires:		perl(LWP::Simple)
Requires:		perl(LWP::UserAgent)
Requires:		perl(Mail::Sender)
Requires:		perl(Math::BigFloat)
Requires:		perl(Math::BigInt)
Requires:		perl(Math::Int64)
Requires:		perl(Module::Load)
Requires:		perl(Net::Ping)
Requires:		perl(Net::DNS)
Requires:		perl(Net::Domain)
Requires:		perl(Net::Interface)
Requires:		perl(NetAddr::IP)
Requires:		perl(POSIX)
Requires:		perl(Pod::Usage)
Requires:		perl(Params::Validate)
Requires:		perl(Readonly)
Requires:		perl(Regexp::Common)
Requires:		perl(Socket)
Requires:		perl(Statistics::Descriptive)
Requires:		perl(Scalar::Util)
Requires:		perl(Sys::Hostname)
Requires:		perl(Sys::Syslog)
Requires:		perl(Text::CSV_XS)
Requires:		perl(Term::ReadKey)
Requires:		perl(Time::HiRes)
Requires:		perl(XML::LibXML) >= 1.62
Requires:		perl(constant)
Requires:		perl(version) >= 0.5
Requires:		perl(fields)
Requires:		perl(aliased)
Requires:		perl(base)
Requires:		chkconfig
Requires:		coreutils
Requires:		libdbi-dbd-mysql
Requires:		mysql-server
Requires:		perl-DBD-MySQL
Requires:		shadow-utils

%description
The perfSONAR_PS PingER MA/MP allows one to make ICMP ping data available in
SQL databases using the perfSONAR protocols. The perfSONAR_PS PingER allows
the collection of data from ICMP ping which is stored inside of the SQL
databases.

%pre
/usr/sbin/groupadd perfsonar 2> /dev/null || :
/usr/sbin/useradd -g perfsonar -r -s /sbin/nologin -c "perfSONAR User" -d /tmp perfsonar 2> /dev/null || :

%prep
%setup -q -n perfSONAR_PS-PingER-server-%{version}.%{relnum}

%build

%install
rm -rf %{buildroot}

make ROOTPATH=%{buildroot}/%{install_base} install

mkdir -p %{buildroot}/etc/init.d

awk "{gsub(/^PREFIX=.*/,\"PREFIX=%{install_base}\"); print}" scripts/%{init_script_1} > scripts/%{init_script_1}.new
install -m 0755 scripts/%{init_script_1}.new %{buildroot}/etc/init.d/%{init_script_1}

%clean
rm -rf %{buildroot}

%post
mkdir -p %{logging_base}
chown perfsonar:perfsonar %{logging_base}

/sbin/chkconfig --add %{init_script_1}

echo "-----------------------------------------------------------------"
echo "                  P L E A S E  R E A D                           "
echo "----- - - - - - - - - - -  - - - - - - -  --  --  - - - - - - - -"
echo "    In order to finish PingER MP/MA installation You have to     "
echo " Run:  /etc/init.d/PingER configure                              "
echo " This will configure the MA/MP database and webservice's endpoint"
echo " More information can be found in the                            "
echo "    /opt/perfsonar_ps/PingER/doc/INSTALL file                    "
echo "-----------------------------------------------------------------"

%files
%defattr(0644,perfsonar,perfsonar,0755)
%doc %{install_base}/doc/*
%config(noreplace) %{install_base}/etc/*
%attr(0755,perfsonar,perfsonar) %{install_base}/bin/*
%attr(0755,perfsonar,perfsonar) %{install_base}/scripts/*
%{install_base}/lib/*
%attr(0755,perfsonar,perfsonar) /etc/init.d/*

%changelog
* Fri Jan 11 2013 asides@es.net 3.3-1
- 3.3 beta release

* Mon Mar 14 2011 maxim@fnal.gov v3.1.14
- added support for the IPv6

* Mon May 17 2010 maxim@fnal.gov v3.1.13
- added pinger service check script with docs and crontab, fixed names

* Tue Jan 08 2010 maxim@fnal.gov v3.1.11
- removed perl prereq

* Tue Sep 22 2009 zurawski@internet2.edu v3.1.7
- useradd option change

* Thu Aug 13 2009 maxim@fnal.gov v3.1.6
- left only empty pinger landmarks file
- suppressed error messages in case of empty landmarks file 
- suppressed error messages when unresolved ip

* Fri Jul 17 2009 maxim@fnal.gov v3.1.5
- pinger landmarks file got fixed

* Mon Jun 24 2009 maxim@fnal.gov v3.1.4
- pinger CLI was enhanced with DB cleanup

* Mon Jun 06 2009 maxim@fnal.gov v3.1.3
- fixed CLP bugs and unresolved source hostname bug

* Mon Mar 23 2009 maxim@fnal.gov v3.1
- refactored for the ps-ps release

* Tue Mar 03 2009 maxim@fnal.gov v0.091
- prepared for MDM release

* Fri Jan 04 2008 aaron@internet2.edu v0.01-1
- Specfile autogenerated.
