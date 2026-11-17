/*
 * MS213x flasher, supports MacroSilicon/Ultrasemi MS2130,
 * MS2130S, MS2131 and MS2131S USB 3 HDMI capture sticks
 *
 * Copyright (C) 2026 by Steve Markgraf <steve@steve-m.de>
 *
 * SPDX-License-Identifier: MIT
 *
 * Permission is hereby granted, free of charge, to any person obtaining
 * a copy of this software and associated documentation files (the
 * "Software"), to deal in the Software without restriction, including
 * without limitation the rights to use, copy, modify, merge, publish,
 * distribute, sublicense, and/or sell copies of the Software, and to
 * permit persons to whom the Software is furnished to do so, subject to
 * the following conditions:
 *
 * The above copyright notice and this permission notice shall be included
 * in all copies or substantial portions of the Software.
 *
 * THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
 * EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
 * MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
 * IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
 * CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
 * TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
 * SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
 */

#include <stdarg.h>
#include <string.h>
#include <stdio.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdbool.h>
#include <sys/stat.h>
#include <libusb.h>
#include <hidapi.h>
#include <getopt.h>

#ifdef WIN32
#include <conio.h>
#endif

#define VERSION_STR "0.10"

typedef struct adapter {
	uint16_t vid;
	uint16_t pid;
	uint8_t hid_if;
	bool ms213xs;
	const char *name;
} adapter_t;

static adapter_t known_devices[] = {
	{ 0x345f, 0x2130, 4, false, "MS2130" },
	{ 0x534d, 0x2130, 4, false, "MS213x-ROM" },
	{ 0x345f, 0x2131, 4, false, "MS2131" },
	{ 0x345f, 0x2132, 4, true,  "MS2130S" },
	{ 0x345f, 0x2133, 4, true,  "MS2131S" },
	{ 0x345f, 0x0001, 0, true,  "MS213xS-ROM" },
};

static struct libusb_device_handle *devh = NULL;
hid_device *handle = NULL;
adapter_t *device = NULL;
bool use_hidapi = false;
bool is_ms213xs = false;
uint8_t ms_hid_if;

#define PAGE_LEN		256
#define HEADER_LEN		0x30
#define CHECKSUM_LEN		4

#define MS2130_FLASH_SIZE	0x10000
#define MS2130S_FLASH_SIZE	(0x18000 + HEADER_LEN + 4)

#define SFR_P2			0xa0
#define SFR_P3			0xb0

/* HID protocol constants */
#define HID_REPORT_GET		0x01
#define HID_REPORT_SET		0x09

#define PBSTR "############################################################"
#define PBWIDTH			60

void print_progress(double ratio)
{
	int val = (int)(ratio * 100);
	int lpad = (int)(ratio * PBWIDTH);
	int rpad = PBWIDTH - lpad;
	printf("\r%3d%% [%.*s%*s]", val, lpad, PBSTR, rpad, "");
	fflush(stdout);
}

int open_device(void)
{
	for (unsigned int i = 0; i < sizeof(known_devices)/sizeof(adapter_t); i++ ) {
#if !defined(WIN32) && !defined(__APPLE__)
		devh = libusb_open_device_with_vid_pid(NULL, known_devices[i].vid, known_devices[i].pid);
		if (devh) {
			device = &known_devices[i];
			break;
		}
#endif
		handle = hid_open(known_devices[i].vid, known_devices[i].pid, NULL);
		if (handle) {
			device = &known_devices[i];
			use_hidapi = true;
			break;
		}
#if defined(WIN32) || defined(__APPLE__)
		devh = libusb_open_device_with_vid_pid(NULL, known_devices[i].vid, known_devices[i].pid);
		if (devh) {
			device = &known_devices[i];
			break;
		}
#endif
	}

	if (device) {
		is_ms213xs = device->ms213xs;
		ms_hid_if = device->hid_if;
		printf("Found %s via %s\n", device->name, use_hidapi ? "hidapi" : "libusb");

		if (devh) {
			if (libusb_kernel_driver_active(devh, ms_hid_if) == 1) {
				printf("Detaching HID Kernel driver\n");
				libusb_detach_kernel_driver(devh, ms_hid_if);
			}
		}

		return 0;
	}

	return -1;
}

int init_usb(void)
{
	/* We try both hidapi and libusb, and use the one that works.
	 * hidapi is preferred e.g. on Windows, as it requires no driver */
	int r = libusb_init(NULL);
	if (r < 0) {
		fprintf(stderr, "Failed to initialize libusb\n");
		exit(1);
	}

	r = hid_init();
	if (r < 0) {
		fprintf(stderr, "Failed to initialize hidapi\n");
		libusb_exit(NULL);
		exit(1);
	}

	r = open_device();
	if (r < 0) {
		fprintf(stderr, "Could not open device\n");
		return r;
	}

	if (!use_hidapi)
		r = libusb_claim_interface(devh, ms_hid_if);

	if (r < 0)
		fprintf(stderr, "usb_claim_interface error %d - use udev rule or run as root\n", r);

	return r;
}

int hidapi_set(uint8_t report_number, unsigned char *data, size_t length)
{
	int r = 0;

#ifdef WIN32
	int transfer_len = length+1;
	unsigned char buf[transfer_len];

	if (!is_ms213xs) {
		buf[0] = report_number;
		memcpy(&buf[1], data, length);
		r = hid_send_feature_report(handle, buf, transfer_len);
	} else
#endif		
		r = hid_send_feature_report(handle, data, length);

	return r;
}

int hidapi_get(uint8_t report_number, unsigned char *data, size_t length)
{
	int transfer_len = length;
#ifdef WIN32
	transfer_len = is_ms213xs ? length : (length + 1);
#endif
	unsigned char buf[transfer_len];
	buf[0] = report_number;

	int r = hid_get_feature_report(handle, buf, transfer_len);

	if (transfer_len > length)
		memcpy(data, &buf[1], length);
	else
		memcpy(data, buf, length);

	return r;
}

#define CTRL_TIMEOUT	300

int ms_get_hid_feature_report(unsigned char *data, size_t length)
{
	int r = 0;
	int report_number = 0x01;
	uint8_t tmp[64];
	int transfer_len = is_ms213xs ? 64 : length;
	uint8_t *buf = is_ms213xs ? tmp : data;

	if (use_hidapi) {
		r = hidapi_get(report_number, buf, transfer_len);
	} else {
	r = libusb_control_transfer(devh,
		LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE | LIBUSB_ENDPOINT_IN,
		HID_REPORT_GET, (3 << 8) | report_number,
		ms_hid_if,
		(unsigned char *)buf, transfer_len,
		CTRL_TIMEOUT);
	}

	/* MS2130S has report buffer shifted by one byte */
	if (is_ms213xs)
		memcpy(data, &buf[1], length);

	return r;
}

int ms_send_hid_feature_report(unsigned char *data, size_t length)
{
	int report_number = 0x01;
	int transfer_len = length;
	uint8_t *buf = data;
	uint8_t tmp[length+1];

	/* MS2130S has report buffer shifted by one byte and longer */
	if (is_ms213xs) {
		transfer_len = length + 1;
		tmp[0] = 0x01;
		memcpy(&tmp[1], data, length);
		buf = tmp;
	}

	if (use_hidapi) {
		return hidapi_set(report_number, buf, transfer_len);
	} else {
	return libusb_control_transfer(devh,
		LIBUSB_REQUEST_TYPE_CLASS | LIBUSB_RECIPIENT_INTERFACE | LIBUSB_ENDPOINT_OUT,
		HID_REPORT_SET, (3 << 8) | report_number,
		ms_hid_if,
		(unsigned char *)buf, transfer_len,
		CTRL_TIMEOUT);
	}
}

int ms_write_reg(uint16_t addr, uint8_t val)
{
	uint8_t cmd[8] = { 0xb6, (addr >> 8), (addr & 0xff), val };

	return ms_send_hid_feature_report(cmd, sizeof(cmd));
}

int ms_read_reg(uint16_t addr, uint8_t *val)
{
	int r = 0;
	uint8_t resp[8];
	uint8_t cmd[8] = { 0xb5, (addr >> 8), (addr & 0xff) };

	r = ms_send_hid_feature_report(cmd, sizeof(cmd));
	if (r < 0)
		return r;

	r = ms_get_hid_feature_report(resp, sizeof(resp));
	if (val)
		*val = resp[3];

	return r;
}

int ms_read_sfr(uint8_t addr, uint8_t *val)
{
	int r = 0;
	uint8_t resp[8];
	uint8_t cmd[8] = { 0xc5, addr };

	r = ms_send_hid_feature_report(cmd, sizeof(cmd));
	if (r < 0)
		return r;

	r = ms_get_hid_feature_report(resp, sizeof(resp));
	if (val)
		*val = resp[2];

	return r;
}

int ms_write_sfr(uint8_t addr, uint8_t val)
{
	uint8_t cmd[8] = { 0xc6, addr, val };

	return ms_send_hid_feature_report(cmd, sizeof(cmd));
}

/* read 256 bytes from flash */
int read_flash_page(uint32_t addr, uint8_t *buf)
{
	int r = 0;
	uint16_t rlen = PAGE_LEN;

	/* Read from flash to buffer: f701aaaaaabbbb00 (aaaaaa=addr, bbbb=len to read) */
	uint8_t read_cmd[8] = { 0xf7, 0x01, (addr >> 16) & 0xff, (addr >> 8) & 0xff, addr & 0xff,
				(rlen >> 8), rlen & 0xff };

	r = ms_send_hid_feature_report(read_cmd, sizeof(read_cmd));
	if (r < 0)
		return r;

	for (uint16_t offs = 0; offs < rlen; offs += 8) {
		/* Read from buffer to host: f700000000aaaa00 (aaaa=offset) */
		uint8_t transfer_cmd[8] = { 0xf7, 0x00, 0x00, 0x00, 0x00, (offs >> 8), offs & 0xff, 0x00 };

		r = ms_send_hid_feature_report(transfer_cmd, sizeof(transfer_cmd));
		if (r < 0)
			return r;

		r = ms_get_hid_feature_report(&buf[offs], 8);
		if (r < 0)
			return r;
	}

	return r;
}

int write_flash_page(uint32_t addr, uint8_t *buf)
{
	int r = 0;
	uint16_t rlen = PAGE_LEN;

	/* Setup flash write: f801aaaaaabbbb00 (aaaaaa=address, bbbb=blocksize) */
	uint8_t write_cmd[8] = { 0xf8, 0x01, (addr >> 16) & 0xff, (addr >> 8) & 0xff, addr & 0xff,
				(rlen >> 8), rlen & 0xff };

	r = ms_send_hid_feature_report(write_cmd, sizeof(write_cmd));
	if (r < 0)
		return r;

	for (uint16_t offs = 0; offs < rlen; offs += 6) {
		/* Write to the buffer: f800cccccccccc(cccccccccccc=data) */
		uint8_t transfer_cmd[8] = { 0xf8, 0x00 };
		memcpy(&transfer_cmd[2], &buf[offs], 6);

		r = ms_send_hid_feature_report(transfer_cmd, sizeof(transfer_cmd));
		if (r < 0)
			return r;
	}

	return r;
}

int erase_flash(void)
{
	uint8_t cmd[8] = { 0xfe };
	return ms_send_hid_feature_report(cmd, sizeof(cmd));
}

int access_flash(uint8_t *buf, uint32_t len, bool write)
{
	int r = 0;

	for (uint32_t addr = 0; (addr < len) && (r >= 0); addr += PAGE_LEN) {
		print_progress((double)addr/(double)len);
		if (write)
			r = write_flash_page(addr, &buf[addr]);
		else
			r = read_flash_page(addr, &buf[addr]);
	}

	print_progress(1);
	printf("\n\n");

	return r;
}

#define SPI_OUT_GPIOS	((1 << 4) | (1 << 3) | (1 << 2))
#define SPI_IN_GPIOS	(1 << 5)

int setup_spi(void)
{
	int r;
	uint8_t val;

	/* configure SPI pin mux */
	r = ms_write_reg(0xf01f, 0x00);
	if (r < 0)
		return r;

	r = ms_read_sfr(SFR_P3, &val);
	if (r < 0)
		return r;

	val |= SPI_IN_GPIOS;
	val &= ~SPI_OUT_GPIOS;
	r = ms_write_sfr(SFR_P3, val);
	if (r < 0)
		return r;

	r = ms_read_sfr(SFR_P2, &val);
	if (r < 0)
		return r;

	val |= SPI_OUT_GPIOS;
	r = ms_write_sfr(SFR_P2, val);
	if (r < 0)
		return r;

	r = ms_write_reg(0xf01f, 0x10);

	return r;
}

uint16_t calculate_header_checksum(uint8_t *data, int len)
{
	uint32_t csum = 0;

	for (int i = 0x02; i < len; i++) {
		if ((i < 0x0c) || (i > 0x0f))
			csum += data[i];
	}

	return csum & 0xffff;
}

uint16_t calculate_code_checksum(uint8_t *data, int len)
{
	uint32_t csum = 0;

	for (int i = 0; i < len; i++)
		csum += data[i];

	return csum & 0xffff;
}

int calc_checksums(uint8_t *fw, uint16_t *header_csum, uint16_t *code_csum, int file_len)
{
	int r = 0;
	int code_len = (fw[0x02] << 8) | fw[0x03];

	/* MS2130S uses code banking and has a fixed length */
	if (is_ms213xs)
		code_len = MS2130S_FLASH_SIZE - HEADER_LEN - CHECKSUM_LEN;

	if ((fw[0] != 0x3c || fw[1] != 0xc3) ||
	    (file_len < (HEADER_LEN + code_len + CHECKSUM_LEN))) {
		fprintf(stderr, "Invalid firmware image\n");
		return -1;
	}

	uint16_t calc_header_csum = calculate_header_checksum(fw, HEADER_LEN);
	uint16_t orig_header_csum  = (fw[HEADER_LEN + code_len + 0] << 8) | fw[HEADER_LEN + code_len + 1];
	if (header_csum)
		*header_csum = calc_header_csum;

	if (calc_header_csum != orig_header_csum) {
		r = -1;
		fprintf(stderr, "Header checksum mismatch: %04x != %04x\n", orig_header_csum, calc_header_csum);
	}

	uint16_t calc_code_csum = calculate_code_checksum(fw + HEADER_LEN, code_len);
	uint16_t orig_code_csum  = (fw[HEADER_LEN + code_len + 2] << 8) | fw[HEADER_LEN + code_len + 3];
	if (code_csum)
		*code_csum = calc_code_csum;

	if (calc_code_csum != orig_code_csum) {
		r = -1;
		fprintf(stderr, "Code checksum mismatch: %04x != %04x\n", orig_code_csum, calc_code_csum);
	}

	return (r < 0) ? r : code_len;
}

int extract_date(uint8_t *fw, char *iso_date)
{
	unsigned int month;
	char *date = is_ms213xs ? (char *)&fw[0x02ec] : (char *)&fw[0x004e];
	const char *months[12] = { "Jan", "Feb", "Mar", "Apr", "May", "Jun",
				   "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" };

	bool valid_month = false;
	for (month = 1; month <= 12; month++) {
		if (!strncmp(months[month-1], date, 3)) {
			valid_month = true;
			break;
		}
	}

	if (!valid_month)
		return -1;

	if (iso_date) {
		/* year */
		strncpy(iso_date, &date[7], 4);
		iso_date[4] = '-';

		/* month */
		snprintf(&iso_date[5], 4, "%02u-", month);

		/* day */
		strncpy(&iso_date[8], &date[4], 2);
		iso_date[10] = '\0';
	} else
		return -2;

	return 0;
}

int backup_fw_to_file(char *filename, size_t flash_size)
{
	uint16_t header_csum, code_csum;
	char auto_filename[256];
	uint8_t *fw = malloc(flash_size + PAGE_LEN);

	if (!fw) {
		perror("malloc");
		return -1;
	}

	printf("\nReading flash (%zu bytes)\n", flash_size);
	int r = access_flash(fw, flash_size, false);
	if (r < 0)
		goto out;

	int code_len = calc_checksums(fw, &header_csum, &code_csum, flash_size);
	if (code_len < 0)
		goto out;

	/* automatically generate filename by appending checksums */
	char fw_date[16];
	r = extract_date(fw, fw_date);
	snprintf(auto_filename, sizeof(auto_filename), "%s_%s_backup_%04x_%04x.bin", device->name,
										    (r == 0) ? fw_date : "undated",
										    header_csum, code_csum);
	r = -1;
	FILE *fp = fopen(filename ? filename : auto_filename, "wb");
	if (!fp) {
		fprintf(stderr, "Error opening file\n");
	} else {
		size_t file_size = flash_size; /* Preserve complete flash, including the tail, for recovery. */
		size_t written = fwrite(fw, 1, file_size, fp);
		if (written != file_size) {
			fprintf(stderr, "Error writing backup file!\n");
		} else
			r = 0;

		printf("Backup saved to %s\n", filename ? filename : auto_filename);
		fclose(fp);
	}

out:
	free(fw);
	return r;
}

int write_fw_to_flash(char *filename, char *backup_filename, size_t flash_size, bool do_backup, bool do_verify)
{
	int r = -1;
	uint8_t *fw = NULL;

	FILE *fp = fopen(filename, "rb");
	if (!fp) {
		fprintf(stderr, "Error opening file: %s\n", filename);
		return -1;
	}

	struct stat finfo;
	fstat(fileno(fp), &finfo);
	size_t file_len = finfo.st_size;

	if (is_ms213xs && (file_len != flash_size)) {
		fprintf(stderr, "Incorrect file size for MS213xS, aborting\n");
		goto out;
	} else if (!is_ms213xs && (file_len > flash_size)) {
		fprintf(stderr, "Incorrect file size for MS213x, aborting\n");
		goto out;;
	}

	fw = malloc(flash_size + PAGE_LEN);
	if (!fw) {
		perror("malloc");
		goto out;
	}

	memset(fw, 0xff, flash_size);

	if (file_len != fread(fw, 1, file_len, fp)) {
		fprintf(stderr, "Failed to read firmware file, aborting\n");
		goto out;
	}

	r = calc_checksums(fw, NULL, NULL, file_len);
	if (r < 0)
		goto out;

	char fw_date[16];
	r = extract_date(fw, fw_date);
	if (r == 0)
		printf("FW date: %s\n", fw_date);

	printf("Checksums of firmware file are correct%s\n", do_backup ? ", creating backup of current firmware" : "");
	if (do_backup) {
		r = backup_fw_to_file(backup_filename, flash_size);
		if (r < 0)
			goto out;
	}

	printf("Erasing flash...\n");
	r = erase_flash();
	if (r < 0) {
		fprintf(stderr, "Erasing flash failed\n");
		goto out;
	}

	printf("\nWriting flash (%zu bytes)\n", file_len);
	r = access_flash(fw, file_len, true);
	if (r < 0) {
		fprintf(stderr, "Writing flash failed\n");
		goto out;
	}

	if (do_verify) {
		uint8_t *verify_buf = malloc(flash_size + PAGE_LEN);
		if (!verify_buf) {
			perror("malloc");
			goto out;
		}

		printf("Verifying flash (%zu bytes)\n", file_len);
		r = access_flash(verify_buf, file_len, false);
		if (r < 0) {
			fprintf(stderr, "Reading flash for verification failed\n");
		} else {
			if (memcmp(fw, verify_buf, file_len) != 0) {
				fprintf(stderr, "Verification failed!\n");
				r = -1;
			} else {
				printf("Successfully written and verified flash\n");
				r = 0;
			}
		}

		free(verify_buf);
	}

out:
	if (fp)
		fclose(fp);

	if (fw)
		free(fw);

	return r;
}

void usage(void)
{
	printf("Usage:\n"
		"\t[-r <read filename>] read flash to file\n"
		"\t[-w <write filename>] write file to flash\n"
		"\t[-n] no verify, skip verification after flashing\n"
		"\t[-h] display this help\n\n");
	exit(1);
}

void print_info(void)
{
	printf("MS213x flasher for MacroSilicon/Ultrasemi MS2130, MS2130S, MS2131 and MS2131S USB 3 HDMI capture sticks\n"
		"https://github.com/steve-m/ms213x_flash - version %s\n"
		"run with -h for help/usage\n\n", VERSION_STR);
}

int main(int argc, char **argv)
{
	int r;
	bool noverify = false;
	char *read_filename = NULL;
	char *write_filename = NULL;

	print_info();

	int opt;
	while ((opt = getopt(argc, argv, "r:w:nh?")) != -1) {
		switch (opt) {
		case 'r':
			read_filename = optarg;
			break;
		case 'w':
			write_filename = optarg;
			break;
		case 'n':
			noverify = true;
			break;
		case 'h':
		case '?':
			usage();
			break;
		default:
			break;
		}
	}

	bool autowrite = (argc == 2) && (optind == 1);

	if (autowrite)
		write_filename = argv[optind];

	r = init_usb();
	if (r < 0)
		goto out;

	size_t flash_size = is_ms213xs ? MS2130S_FLASH_SIZE : MS2130_FLASH_SIZE;

	r = setup_spi();
	if (r < 0)
		goto out;

	if (write_filename)
		r = write_fw_to_flash(write_filename, read_filename, flash_size, autowrite || read_filename, !noverify);
	else
		r = backup_fw_to_file(read_filename, flash_size);

	if (r >= 0)
		printf("Done.\n");

out:
	if (devh) {
		libusb_release_interface(devh, ms_hid_if);
		libusb_close(devh);
	}

	if (handle)
		hid_close(handle);

	libusb_exit(NULL);
	hid_exit();

#ifdef WIN32
	if ((argc == 1) || autowrite) {
		printf("\nPress any key to exit...\n");
		getch();
	}
#endif

	return r >= 0 ? r : -r;
}
