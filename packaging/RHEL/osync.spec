Name:		osync           
Version:        1.2
Release:        beta.1%{?dist}
Summary:        robust file synchronization tool

Group:		Applications/File
License:        BSD
URL:            https://www.netpower.fr/osync
Source0:        https://github.com/deajan/osync/archive/master.zip

Requires:       rsync openssh-server
BuildArch: 	noarch

%description

%prep
%setup -q


%build
%configure

%install
rm -rf ${RPM_BUILD_ROOT}
mkdir -p ${RPM_BUILD_ROOT}/usr/bin
install -m 755 osync.sh ${RPM_BUILD_ROOT}%{_bindir}
install -m 755 osync-batch.sh ${RPM_BUILD_ROOT}%{_bindir}


%files
%defattr(-,root,root)
%attr(755,root,root) %{_bindir}/osync.sh
%doc



%changelog
* 30 Aug 2016 Orsiris de Jong <ozy@netpower.fr>
- Initial spec file
