%define name osync
%define version 1.2RC3
%define gitsource https://github.com/deajan/%{name}/archive/v%{version}.zip

%define use_systemd 1
%{?el5:%define use_systemd 0}
%{?el6:%define use_systemd 0}

Name:		%{name}
Version:        %{version}
Release:        1%{?dist}
Summary:        robust file synchronization tool

Group:		Applications/File
License:        BSD
URL:            https://www.netpower.fr/osync
Source0:        %{gitsource}

BuildRequires:  wget
Requires:       rsync openssh-server bash wget inotify-tools
BuildArch: 	noarch

%description
A robust two way (bidirectional) file sync script based on rsync with fault tolerance, time control and ACL synchronization.

#%prep
#%setup -q
#%build
#%configure

%install
wget --no-check-certificate --timeout=5 -O %{_sourcedir}/%{name}-%{version}.zip %{gitsource}
( cd %{_sourcedir} && unzip %{_sourcedir}/%{name}-%{version}.zip )
rm -rf ${RPM_BUILD_ROOT}
mkdir -p ${RPM_BUILD_ROOT}%{_bindir}
mkdir -p ${RPM_BUILD_ROOT}%{_unitdir}
install -m 755 %{_sourcedir}/%{name}-%{version}/osync.sh ${RPM_BUILD_ROOT}%{_bindir}
install -m 755 %{_sourcedir}/%{name}-%{version}/osync-batch.sh ${RPM_BUILD_ROOT}%{_bindir}
install -m 0755 -d ${RPM_BUILD_ROOT}/etc/osync
install -m 0644 %{_sourcedir}/%{name}-%{version}/sync.conf.example ${RPM_BUILD_ROOT}/etc/osync
%if %use_systemd
install -m 0755 %{_sourcedir}/%{name}-%{version}/osync-srv@.service ${RPM_BUILD_ROOT}%{_unitdir}
%else
install -m 0755 %{_sourcedir}/%{name}-%{version}/osync-srv ${RPM_BUILD_ROOT}/etc/init.d
%endif

%files
%defattr(-,root,root)
%attr(755,root,root) %{_bindir}/osync.sh
%attr(755,root,root) %{_bindir}/osync-batch.sh
%attr(644,root,root) /etc/osync/sync.conf.example
%if %use_systemd
%attr(755,root,root) %{_unitdir}/osync-srv@.service
%else
%attr(755,root,root) /etc/init.d/osync-srv
%endif

%doc

%changelog
* Wed Feb 15 2017 Richard Grainger <grainger@gmail.com>
- Update version
- Download source archive based on version
- Add inotify-tools as dependency

* Sun Dec 18 2016 Orsiris de Jong <ozy@netpower.fr>
- Add systemd / initV differentiation
- Make source autodownload work
- Disable all macros except install

* Tue Aug 30 2016 Orsiris de Jong <ozy@netpower.fr>
- Initial spec file
