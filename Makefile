# Copyright 2018 Google LLC
#
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License
# version 2 as published by the Free Software Foundation.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin Street, Fifth Floor, Boston, MA 02110-1301, USA.

# By default, assume this was checked out as a submodule of the Hafnium repo
# and that Linux was checked out along side that checkout. These paths can be
# overridden if that assumption is incorrect.
HAFNIUM_PATH ?= $(PWD)/../..

ifneq ($(KERNELRELEASE),)

obj-m += hafnium.o

hafnium-y += main.o
hafnium-y += hf_call.o

ccflags-y = -I$(HAFNIUM_PATH)/inc/vmapi

else

KERNEL_PATH ?= $(HAFNIUM_PATH)/../linux
ARCH ?= arm64
CROSS_COMPILE ?= aarch64-linux-gnu-

all:
	make -C $(KERNEL_PATH) M=$(PWD) ARCH=$(ARCH) CROSS_COMPILE=$(CROSS_COMPILE) modules

clean:
	make -C $(KERNEL_PATH) M=$(PWD) clean

endif
