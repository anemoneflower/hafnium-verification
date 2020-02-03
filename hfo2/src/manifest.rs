/*
 * Copyright 2019 Sanguk Park
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     https://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

use core::convert::TryInto;
use core::fmt::{self, Write};
use core::ptr;

use crate::fdt::*;
use crate::memiter::*;
use crate::types::*;

use arrayvec::ArrayVec;

const VM_NAME_BUF_SIZE: usize = 2 + 5 + 1; // "vm" + number + null terminator
const_assert!(MAX_VMS <= 99999);

#[derive(PartialEq, Debug)]
pub enum Error {
    CorruptedFdt,
    NoRootFdtNode,
    NoHypervisorFdtNode,
    ReservedVmId,
    NoPrimaryVm,
    TooManyVms,
    PropertyNotFound,
    MalformedString,
    MalformedInteger,
    IntegerOverflow,
}

impl Into<&'static str> for Error {
    fn into(self) -> &'static str {
        use Error::*;
        match self {
            CorruptedFdt => "Manifest failed FDT validation",
            NoRootFdtNode => "Could not find root node of manifest",
            NoHypervisorFdtNode => "Could not find \"hypervisor\" node in manifest",
            ReservedVmId => "Manifest defines a VM with a reserved ID",
            NoPrimaryVm => "Manifest does not contain a primary VM entry",
            TooManyVms => {
                "Manifest specifies more VMs than Hafnium has statically allocated space for"
            }
            PropertyNotFound => "Property not found",
            MalformedString => "Malformed string property",
            MalformedInteger => "Malformed integer property",
            IntegerOverflow => "Integer overflow",
        }
    }
}

/// Holds information about one of the VMs described in the manifest.
#[derive(Debug)]
pub struct ManifestVm {
    // Properties defined for both primary and secondary VMs.
    pub debug_name: MemIter,

    // Properties specific to secondary VMs.
    pub kernel_filename: MemIter,
    pub mem_size: u64,
    pub vcpu_count: spci_vcpu_count_t,
}

/// Hafnium manifest parsed from FDT.
#[derive(Debug)]
pub struct Manifest {
    pub vms: ArrayVec<[ManifestVm; MAX_VMS]>,
}

/// Generates a string with the two letters "vm" followed by an integer.
fn generate_vm_node_name<'a>(
    buf: &'a mut [u8; VM_NAME_BUF_SIZE],
    vm_id: spci_vm_id_t,
) -> &'a mut [u8] {
    struct BufWrite<'a> {
        buf: &'a mut [u8; VM_NAME_BUF_SIZE],
        size: usize,
    }

    impl<'a> Write for BufWrite<'a> {
        fn write_str(&mut self, s: &str) -> Result<(), fmt::Error> {
            let dest = self
                .buf
                .get_mut(self.size..(self.size + s.len()))
                .ok_or(fmt::Error)?;
            dest.copy_from_slice(s.as_bytes());
            self.size += s.len();

            Ok(())
        }
    }

    let mut buf = BufWrite { buf, size: 0 };
    write!(buf, "vm{}\0", vm_id).unwrap();
    &mut buf.buf[..buf.size]
}

impl<'a> FdtNode<'a> {
    /// TODO(HfO2): This function is marked `inline(never)`, to prevent stack overflow. It is still
    /// mysterious why inlining this function into ManifestVm::new makes stack overflow.
    #[inline(never)]
    fn read_string(&self, property: *const u8) -> Result<MemIter, Error> {
        let data = self
            .read_property(property)
            .map_err(|_| Error::PropertyNotFound)?;

        if data[data.len() - 1] != b'\0' {
            return Err(Error::MalformedString);
        }

        Ok(unsafe { MemIter::from_raw(data.as_ptr(), data.len() - 1) })
    }

    fn read_u64(&self, property: *const u8) -> Result<u64, Error> {
        let data = self
            .read_property(property)
            .map_err(|_| Error::PropertyNotFound)?;

        fdt_parse_number(data).ok_or(Error::MalformedInteger)
    }

    fn read_u16(&self, property: *const u8) -> Result<u16, Error> {
        let value = self.read_u64(property)?;

        value.try_into().map_err(|_| Error::IntegerOverflow)
    }
}

impl ManifestVm {
    fn new<'a>(node: &FdtNode<'a>, vm_id: spci_vm_id_t) -> Result<Self, Error> {
        let debug_name = node.read_string("debug_name\0".as_ptr())?;
        let (kernel_filename, mem_size, vcpu_count) = if vm_id != HF_PRIMARY_VM_ID {
            (
                node.read_string("kernel_filename\0".as_ptr())?,
                node.read_u64("mem_size\0".as_ptr())?,
                node.read_u16("vcpu_count\0".as_ptr())?,
            )
        } else {
            (unsafe { MemIter::from_raw(ptr::null(), 0) }, 0, 0)
        };

        Ok(Self {
            debug_name,
            kernel_filename,
            mem_size,
            vcpu_count,
        })
    }
}

impl Manifest {
    /// Parse manifest from FDT.
    pub fn init(&mut self, fdt: &MemIter) -> Result<(), Error> {
        let mut vm_name_buf = Default::default();
        let mut found_primary_vm = false;
        let mut hyp_node = FdtNode::new_root(unsafe { &*(fdt.get_next() as *const _) })
            .ok_or(Error::CorruptedFdt)?;
        unsafe {
            self.vms.set_len(0);
        }

        hyp_node
            .find_child("\0".as_ptr())
            .ok_or(Error::NoRootFdtNode)?;
        hyp_node
            .find_child("hypervisor\0".as_ptr())
            .ok_or(Error::NoHypervisorFdtNode)?;

        // Iterate over reserved VM IDs and check no such nodes exist.
        for vm_id in 0..HF_VM_ID_OFFSET {
            let mut vm_node = hyp_node.clone();
            let vm_name = generate_vm_node_name(&mut vm_name_buf, vm_id);

            if vm_node.find_child(vm_name.as_ptr()).is_some() {
                return Err(Error::ReservedVmId);
            }
        }

        // Iterate over VM nodes until we find one that does not exist.
        for i in 0..=MAX_VMS as spci_vm_id_t {
            let vm_id = HF_VM_ID_OFFSET + i;
            let mut vm_node = hyp_node.clone();
            let vm_name = generate_vm_node_name(&mut vm_name_buf, vm_id);

            if vm_node.find_child(vm_name.as_ptr()).is_none() {
                break;
            }

            if i == MAX_VMS as spci_vm_id_t {
                return Err(Error::TooManyVms);
            }

            if vm_id == HF_PRIMARY_VM_ID {
                assert!(found_primary_vm == false); // sanity check
                found_primary_vm = true;
            }

            self.vms.push(ManifestVm::new(&vm_node, vm_id)?);
        }

        if !found_primary_vm {
            Err(Error::NoPrimaryVm)
        } else {
            Ok(())
        }
    }
}

#[cfg(test)]
mod test {
    use super::*;
    use core::mem;

    // DTB files compiled with:
    //   $ dtc -I dts -O dtb --out-version 17 test.dts | xxd -i

    #[test]
    fn empty_root() {
        #[repr(align(4))]
        struct AlignedDtb {
            data: [u8; 72],
        }

        /// /dts-v1/;
        ///
        /// / {
        /// };
        static DTB: AlignedDtb = AlignedDtb {
            data: [
                0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x00, 0x48, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00,
                0x00, 0x48, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x10,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
                0x00, 0x09,
            ],
        };

        let it = unsafe { MemIter::from_raw(DTB.data.as_ptr(), DTB.data.len()) };
        let mut m: Manifest = unsafe { mem::MaybeUninit::uninit().assume_init() };
        assert_eq!(m.init(&it).unwrap_err(), Error::NoHypervisorFdtNode);
    }

    #[test]
    fn no_vms() {
        #[repr(align(4))]
        struct AlignedDtb {
            data: [u8; 92],
        }

        /// /dts-v1/;
        ///
        /// / {
        ///  hypervisor {
        ///  };
        /// };
        static DTB: AlignedDtb = AlignedDtb {
            data: [
                0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x00, 0x5c, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00,
                0x00, 0x5c, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x10,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x24, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x68, 0x79,
                0x70, 0x65, 0x72, 0x76, 0x69, 0x73, 0x6f, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02,
                0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x09,
            ],
        };

        let it = unsafe { MemIter::from_raw(DTB.data.as_ptr(), DTB.data.len()) };
        let mut manifest: Manifest = unsafe { mem::MaybeUninit::uninit().assume_init() };
        assert_eq!(manifest.init(&it).unwrap_err(), Error::NoPrimaryVm);
    }

    #[test]
    fn reserved_vmid() {
        #[repr(align(4))]
        struct AlignedDtb {
            data: [u8; 263],
        }

        /// /dts-v1/;
        ///
        /// / {
        ///  hypervisor {
        ///      vm1 {
        ///          debug_name = "primary_vm";
        ///      };
        ///      vm0 {
        ///          debug_name = "reserved_vm";
        ///          vcpu_count = <1>;
        ///          mem_size = <4096>;
        ///          kernel_filename = "kernel";
        ///      };
        ///  };
        /// };
        static DTB: AlignedDtb = AlignedDtb {
            data: [
                0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x01, 0x07, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00,
                0x00, 0xd8, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x10,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00, 0xa0, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x68, 0x79,
                0x70, 0x65, 0x72, 0x76, 0x69, 0x73, 0x6f, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
                0x76, 0x6d, 0x31, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x00,
                0x00, 0x00, 0x70, 0x72, 0x69, 0x6d, 0x61, 0x72, 0x79, 0x5f, 0x76, 0x6d, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x76, 0x6d, 0x30, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x0c, 0x00, 0x00, 0x00, 0x00, 0x72, 0x65, 0x73, 0x65,
                0x72, 0x76, 0x65, 0x64, 0x5f, 0x76, 0x6d, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00,
                0x00, 0x04, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x03,
                0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x10, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x07, 0x00, 0x00, 0x00, 0x1f, 0x6b, 0x65, 0x72, 0x6e,
                0x65, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00,
                0x00, 0x02, 0x00, 0x00, 0x00, 0x09, 0x64, 0x65, 0x62, 0x75, 0x67, 0x5f, 0x6e, 0x61,
                0x6d, 0x65, 0x00, 0x76, 0x63, 0x70, 0x75, 0x5f, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00,
                0x6d, 0x65, 0x6d, 0x5f, 0x73, 0x69, 0x7a, 0x65, 0x00, 0x6b, 0x65, 0x72, 0x6e, 0x65,
                0x6c, 0x5f, 0x66, 0x69, 0x6c, 0x65, 0x6e, 0x61, 0x6d, 0x65, 0x00,
            ],
        };

        let it = unsafe { MemIter::from_raw(DTB.data.as_ptr(), DTB.data.len()) };
        let mut manifest: Manifest = unsafe { mem::MaybeUninit::uninit().assume_init() };
        assert_eq!(manifest.init(&it).unwrap_err(), Error::ReservedVmId);
    }

    #[test]
    fn vcpu_count_limit() {
        #[repr(align(4))]
        struct AlignedDtb {
            data: [u8; 243],
        }

        /// /dts-v1/;
        ///
        /// / {
        ///  hypervisor {
        ///      vm1 {
        ///          debug_name = "";
        ///      };
        ///      vm0 {
        ///          debug_name = "";
        ///          vcpu_count = <65535>;
        ///          mem_size = <0>;
        ///          kernel_filename = "";
        ///      };
        ///  };
        /// };
        static DTB_LAST_VALID: AlignedDtb = AlignedDtb {
            data: [
                0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x00, 0xf3, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00,
                0x00, 0xc4, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x10,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00, 0x8c, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x68, 0x79,
                0x70, 0x65, 0x72, 0x76, 0x69, 0x73, 0x6f, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
                0x76, 0x6d, 0x31, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
                0x76, 0x6d, 0x32, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04,
                0x00, 0x00, 0x00, 0x0b, 0x00, 0x00, 0xff, 0xff, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00,
                0x00, 0x04, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x09,
                0x64, 0x65, 0x62, 0x75, 0x67, 0x5f, 0x6e, 0x61, 0x6d, 0x65, 0x00, 0x76, 0x63, 0x70,
                0x75, 0x5f, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x6d, 0x65, 0x6d, 0x5f, 0x73, 0x69,
                0x7a, 0x65, 0x00, 0x6b, 0x65, 0x72, 0x6e, 0x65, 0x6c, 0x5f, 0x66, 0x69, 0x6c, 0x65,
                0x6e, 0x61, 0x6d, 0x65, 0x00,
            ],
        };

        /// Same as above, set "vcpu_count" to 65536.
        static DTB_FIRST_INVALID: AlignedDtb = AlignedDtb {
            data: [
                0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x00, 0xf3, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00,
                0x00, 0xc4, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x10,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x00, 0x8c, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x68, 0x79,
                0x70, 0x65, 0x72, 0x76, 0x69, 0x73, 0x6f, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
                0x76, 0x6d, 0x31, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
                0x76, 0x6d, 0x32, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04,
                0x00, 0x00, 0x00, 0x0b, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00,
                0x00, 0x04, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x1f, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x09,
                0x64, 0x65, 0x62, 0x75, 0x67, 0x5f, 0x6e, 0x61, 0x6d, 0x65, 0x00, 0x76, 0x63, 0x70,
                0x75, 0x5f, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x6d, 0x65, 0x6d, 0x5f, 0x73, 0x69,
                0x7a, 0x65, 0x00, 0x6b, 0x65, 0x72, 0x6e, 0x65, 0x6c, 0x5f, 0x66, 0x69, 0x6c, 0x65,
                0x6e, 0x61, 0x6d, 0x65, 0x00,
            ],
        };

        let it =
            unsafe { MemIter::from_raw(DTB_LAST_VALID.data.as_ptr(), DTB_LAST_VALID.data.len()) };
        let mut m: Manifest = unsafe { mem::MaybeUninit::uninit().assume_init() };
        m.init(&it).unwrap();
        assert_eq!(m.vms.len(), 2);
        assert_eq!(m.vms[1].vcpu_count, u16::max_value());

        let it = unsafe {
            MemIter::from_raw(
                DTB_FIRST_INVALID.data.as_ptr(),
                DTB_FIRST_INVALID.data.len(),
            )
        };
        assert_eq!(m.init(&it).unwrap_err(), Error::IntegerOverflow);
    }

    #[test]
    fn valid() {
        #[repr(align(4))]
        struct AlignedDtb {
            data: [u8; 383],
        }

        /// /dts-v1/;
        ///
        /// / {
        ///  hypervisor {
        ///      vm1 {
        ///          debug_name = "primary_vm";
        ///      };
        ///      vm3 {
        ///          debug_name = "second_secondary_vm";
        ///          vcpu_count = <43>;
        ///          mem_size = <0x12345>;
        ///          kernel_filename = "second_kernel";
        ///      };
        ///      vm2 {
        ///          debug_name = "first_secondary_vm";
        ///          vcpu_count = <42>;
        ///          mem_size = <12345>;
        ///          kernel_filename = "first_kernel";
        ///      };
        ///  };
        /// };
        static DTB: AlignedDtb = AlignedDtb {
            data: [
                0xd0, 0x0d, 0xfe, 0xed, 0x00, 0x00, 0x01, 0x7f, 0x00, 0x00, 0x00, 0x38, 0x00, 0x00,
                0x01, 0x50, 0x00, 0x00, 0x00, 0x28, 0x00, 0x00, 0x00, 0x11, 0x00, 0x00, 0x00, 0x10,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x2f, 0x00, 0x00, 0x01, 0x18, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01, 0x68, 0x79,
                0x70, 0x65, 0x72, 0x76, 0x69, 0x73, 0x6f, 0x72, 0x00, 0x00, 0x00, 0x00, 0x00, 0x01,
                0x76, 0x6d, 0x31, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x00,
                0x00, 0x00, 0x70, 0x72, 0x69, 0x6d, 0x61, 0x72, 0x79, 0x5f, 0x76, 0x6d, 0x00, 0x00,
                0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01, 0x76, 0x6d, 0x33, 0x00, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x14, 0x00, 0x00, 0x00, 0x00, 0x73, 0x65, 0x63, 0x6f,
                0x6e, 0x64, 0x5f, 0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64, 0x61, 0x72, 0x79, 0x5f, 0x76,
                0x6d, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x0b,
                0x00, 0x00, 0x00, 0x2b, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x04, 0x00, 0x00,
                0x00, 0x16, 0x00, 0x01, 0x23, 0x45, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x0e,
                0x00, 0x00, 0x00, 0x1f, 0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64, 0x5f, 0x6b, 0x65, 0x72,
                0x6e, 0x65, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x01,
                0x76, 0x6d, 0x32, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00, 0x00, 0x13, 0x00, 0x00,
                0x00, 0x00, 0x66, 0x69, 0x72, 0x73, 0x74, 0x5f, 0x73, 0x65, 0x63, 0x6f, 0x6e, 0x64,
                0x61, 0x72, 0x79, 0x5f, 0x76, 0x6d, 0x00, 0x00, 0x00, 0x00, 0x00, 0x03, 0x00, 0x00,
                0x00, 0x04, 0x00, 0x00, 0x00, 0x0b, 0x00, 0x00, 0x00, 0x2a, 0x00, 0x00, 0x00, 0x03,
                0x00, 0x00, 0x00, 0x04, 0x00, 0x00, 0x00, 0x16, 0x00, 0x00, 0x30, 0x39, 0x00, 0x00,
                0x00, 0x03, 0x00, 0x00, 0x00, 0x0d, 0x00, 0x00, 0x00, 0x1f, 0x66, 0x69, 0x72, 0x73,
                0x74, 0x5f, 0x6b, 0x65, 0x72, 0x6e, 0x65, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00,
                0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x09,
                0x64, 0x65, 0x62, 0x75, 0x67, 0x5f, 0x6e, 0x61, 0x6d, 0x65, 0x00, 0x76, 0x63, 0x70,
                0x75, 0x5f, 0x63, 0x6f, 0x75, 0x6e, 0x74, 0x00, 0x6d, 0x65, 0x6d, 0x5f, 0x73, 0x69,
                0x7a, 0x65, 0x00, 0x6b, 0x65, 0x72, 0x6e, 0x65, 0x6c, 0x5f, 0x66, 0x69, 0x6c, 0x65,
                0x6e, 0x61, 0x6d, 0x65, 0x00,
            ],
        };

        let it = unsafe { MemIter::from_raw(DTB.data.as_ptr(), DTB.data.len()) };
        let mut m: Manifest = unsafe { mem::MaybeUninit::uninit().assume_init() };
        m.init(&it).unwrap();
        assert_eq!(m.vms.len(), 3);

        let vm = &m.vms[0];
        assert!(unsafe { vm.debug_name.iseq("primary_vm\0".as_ptr()) });

        let vm = &m.vms[1];
        assert!(unsafe { vm.debug_name.iseq("first_secondary_vm\0".as_ptr()) });
        assert_eq!(vm.vcpu_count, 42);
        assert_eq!(vm.mem_size, 12345);
        assert!(unsafe { vm.kernel_filename.iseq("first_kernel\0".as_ptr()) });

        let vm = &m.vms[2];
        assert!(unsafe { vm.debug_name.iseq("second_secondary_vm\0".as_ptr()) });
        assert_eq!(vm.vcpu_count, 43);
        assert_eq!(vm.mem_size, 0x12345);
        assert!(unsafe { vm.kernel_filename.iseq("second_kernel\0".as_ptr()) });
    }
}