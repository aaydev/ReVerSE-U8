// ==============================================================================
//
// Project: Z80 NMOS Silicon-to-RTL CPU Core
//
// Description: Fully synchronous, cycle-accurate NMOS Z80 drop-in replacement.
//              Meticulously reconstructed and translated from a transistor-level
//              netlist into a clean, latch-free synchronous RTL design.
//
// Component: Z80.v (Main Core Module)
//
// Version: 0.9.2-alpha (with Savestate support)
//
// Engineer: Andrey Titov (dr.Titus)
// Create Date: 2024-10-18
// Release Date: 2026-09-26
// Modified: 2026-10-08 (Savestate ports added)
//
// Source Data: Transistor netlist sourced from the Z80 Explorer project by Goran Devic.
//
// References:
//   - Reverse engineering Z80:
//     https://zx-pk.ru/threads/34173-revers-inzhiniring-z80.html (in Russian)
//   - Z80 Explorer project: https://github.com/gdevic/Z80Explorer
//   - Project repository: https://github.com/dr-Titus/z80-silicon-rtl/
//
// Copyright (c) 2022-2026 Andrey Titov (dr.Titus). All rights reserved.
// This source code is licensed under the GNU General Public License v3 (GPL v3).
//
// ==============================================================================
module Z80 #(
    parameter T2Write = 1  // 0 => WR_n active in T3, 1 => WR_n active in T2
)(
    input             clk,              // Тактовый сигнал (сигнал инвертировать НЕ надо)
    input      [7:0]  data_in,          // Шина данных (ввод)
    output     [7:0]  data_out,         // Шина данных (вывод)
    output    [15:0]  adr,              // Шина адреса
    output            mreq,             // Запрос доступа к памяти (активный уровень высокий, на чипе инвертирован)
    output            iorq,             // Запрос ввода-вывода (активный уровень высокий, на чипе инвертирован)
    output            rd,               // Чтение памяти или портов ввода-вывода (активный уровень высокий, на чипе инвертирован)
    output            wr,               // Запись в память или порты ввода-вывода (активный уровень высокий, на чипе инвертирован)
    output            data_z,           // Перевод шины данных в Z-состояние
    output            adr_z,            // Перевод шины адреса в Z-состояние
    output            controls_z,       // Перевод управляющих сигналов MREQ, IORQ, RD, WR в Z-состояние
    output            rfsh,             // Запрос регенерации памяти (активный уровень высокий, на чипе инвертирован)
    output            p_m1,             // Машинный цикл M1 (активный уровень высокий, на чипе инвертирован)
    output            halt,             // Сигнал состояния останова (активный уровень высокий, на чипе инвертирован)
    input             p_wait,           // Запрос ожидания памяти (активный уровень высокий, на чипе инвертирован)
    input             p_int,            // Запрос маскируемого прерывания (активный уровень высокий, на чипе инвертирован)
    input             nmi,              // Запрос немаскируемого прерывания (активный уровень высокий, на чипе инвертирован)
    input             reset,            // Сброс (активный уровень высокий, на чипе инвертирован)
    input             busrq,            // Запрос доступа к шине (активный уровень высокий, на чипе инвертирован)
    output            busack,           // Предоставление доступа к шине (активный уровень высокий, на чипе инвертирован)
    // === SAVESTATE PORTS ===
    output    [15:0]  save_pc,          // Текущее значение PC для сохранения
    output     [7:0]  save_int,         // Состояние прерываний: {4'b0, IFF2, IFF1, IM1, IM0}
    input     [15:0]  restore_pc,       // Значение PC для восстановления
    input      [7:0]  restore_int,      // Состояние прерываний для восстановления
    input             restore_en        // Строб восстановления (активный высокий)
);

    // === Внутренние шины и сигналы ===
    wire [6:1]  t;                          // Шина тактов T1-T6
    wire [5:1]  m;                          // Шина машинных циклов M1-M5
    wire        res_tclk;                   // Сигнал сброса счета тактов T
    wire        res_mclk;                   // Сигнал сброса счета машинных циклов M
    wire        t1_stall;                   // Сигнал приостановки цикла T1 при прямом доступе к шине
    wire        req_write;                  // Сигнал запроса записи
    wire        dis_bus;                    // Сигнал запрета чтения/записи шины
    wire        sync_res;                   // Сигнал синхронного сброса, выставляется на полтакта раньше res, синхронен с CLK
    wire        res;                        // Внутренний сигнал сброса, синхронен с /CLK
    wire        spec_res;                   // Сигнал специального сброса
    wire        int_ack;                    // Сигнал INT_ACK
    wire        nmi_ack;                    // Сигнал NMI_ACK
    wire        int_stop_pcr;               // Сигнал остановки счетчика PCR во время INT/HALT
    wire        index_math;                 // Сигнал режима вычисления индекса
    wire        base_set;                   // Сигнал выбора базового набора команд
    wire        ed_set;                     // Сигнал выбора набора команд ED
    wire        cb_set;                     // Сигнал выбора набора команд CB
    wire        idx_set;                    // Сигнал выбора набора команд DD/FD
    wire        idx_cb;                     // Сигнал выбора набора команд IDX CB
    wire        cond_done;                  // Сигнал совпадения условия
    wire        pcr_equal_one;              // Сигнал того, что PCR = 0x0001
    wire [3:0]  cond;                       // Шина условий/декодера типа сдвига
    wire        flag_z;                     // Флаг нуля Z
    wire        sel_acc;                    // Сигнал выбора аккумулятора по умолчанию
    wire [2:0]  reg_n;                      // Трехбитный код регистровой пары
    wire        sel_reg_src;                // Запрос регистра-источника
    wire        sel_reg_dst;                // Запрос регистра-приемника
    wire        sel_reg_src_r;              // Запрос регистра-источника или IR
    wire        sel_reg_dst_r;              // Запрос регистра-приемника или IR
    wire        sel_pc_src;                 // Сигнал выбора PC источником
    wire        sel_pc_dst;                 // Сигнал выбора PC приемником
    wire        grp_wrdata;                 // Группа команд, записывающих данные в память/порты
    wire        grp_block;                  // Группа блочных команд
    wire        grp_sp;                     // Группа команд, работающих со стеком
    wire        grp_imm8;                   // Группа команд, читающих один байт непосредственных данных
    wire        grp_a_mem_io;               // Группа команд записи/чтения памяти/портов
    wire        grp_dst_af;                 // Группа команд, работающих с регистром-приемником AF
    wire        grp_shift;                  // Группа команд сдвигов
    wire        grp_m_hl;                   // Группа команд с адресацией (HL)
    wire        grp_prefix;                 // Группа команд, работающих с префиксами DD/FD/CB/ED
    wire        grp_idx;                    // Группа команд с индексной адресацией
    wire        grp_branch;                 // Группа команд переходов
    wire        grp_dir16;                  // Группа команд записи/чтения регистровой пары по непосредственному адресу
    wire        grp_store16;                // Группа команд записи регистровой пары по непосредственному адресу
    wire        add_sub_hl;                 // Группа команд сложения/вычитания с HL
    wire        grp_io;                     // Группа команд ввода/вывода
    wire        grp_offset_raw;             // Группа команд, работающих с относительной адресацией
    wire        grp_m4;                     // Группа команд, требующих цикл M4
    wire        grp_noalum1;                // Группа команд, не требующих АЛУ в цикле M1
    wire        grp_data16;                 // Группа команд для работы с 16-битными данными
    wire        grp_reg_dst;                // Группа команд, требующих регистр-приемник
    wire        grp_ldi_cpi;                // Группа команд LD(I/D)(R)/CP(I/D)(R)
    wire        grp_imm16;                  // Группа команд, читающих два байта непосредственных данных
    wire        grp_imm;                    // Группа команд, использующих непосредственную адресацию
    wire        grp_m3_t3_last;             // Группа команд, заканчивающихся тактом M3.T3
    wire        grp_m3_not_last_raw;        // Группа команд, не заканчивающихся циклом M3
    wire        sel_rst_nmi_im1;            // Сигнал команд RST/NMI/IM 1
    wire        sel_im1;                    // Сигнал прерывания IM 1
    wire        sel_im2;                    // Сигнал прерывания IM 2
    wire        sel_nmi;                    // Сигнал прерывания NMI
    wire        sel_af;                     // Сигнал выбора регистра AF
    wire        sel_af_;                    // Сигнал выбора регистра AF'
    wire        sel_hl;                     // Сигнал выбора регистра HL
    wire        sel_hl_;                    // Сигнал выбора регистра HL'
    wire        sel_de;                     // Сигнал выбора регистра DE
    wire        sel_de_;                    // Сигнал выбора регистра DE'
    wire        sel_bc;                     // Сигнал выбора регистра BC
    wire        sel_bc_;                    // Сигнал выбора регистра BC'
    wire        sel_ix;                     // Сигнал выбора регистра IX
    wire        sel_iy;                     // Сигнал выбора регистра IY
    wire        sel_sp;                     // Сигнал выбора регистра SP
    wire        sel_wz;                     // Сигнал выбора регистра WZ
    wire        sel_ir;                     // Сигнал выбора регистра IR
    wire        sel_pc;                     // Сигнал выбора регистра PC
    wire        req_flags;                  // Сигнал работы с флагами
    wire        save_flags;                 // Сигнал записи флагов на FBUS
    wire        load_flags;                 // Сигнал сохранения текущих флагов с FBUS в кеше флагов
    wire        write_regh;                 // Сигнал записи данных в старшую часть выбранного регистра с шины HBUS_IN
    wire        write_regl;                 // Сигнал записи данных в младшую часть выбранного регистра с шины FBUS_IN
    wire        read_regh;                  // Сигнал чтения данных из старшей части выбранного регистра на шину HBUS_OUT
    wire        read_regl;                  // Сигнал чтения данных из младшей части выбранного регистра на шину FBUS_OUT
    wire [7:0]  command;                    // Регистр COMMAND
    wire [98:0] pla;                        // Шина ПЛМ
    wire        join_rp;                    // Сигнал обьединения основного банка регистров и банка регистров-указателей
    wire [7:0]  hbus_in;                    // Шина данных для записи в регистры, старшая часть HBUS_IN
    wire [7:0]  fbus_in;                    // Шина данных для записи в регистры, младшая часть FBUS_IN (только для F и F')
    wire [15:0] pcrbus_in;                  // Шина данных для записи в регистры IR и PC, или во все регистры при JOIN_RP = 1
    wire [7:0]  hbus_out;                   // Шина данных для чтения регистра, старшая часть HBUS_OUT
    wire [7:0]  fbus_out;                   // Шина данных для чтения регистра, младшая часть FBUS_OUT (только для F и F')
    wire [15:0] pcrbus_out;                 // Шина данных для чтения регистров IR и PC, или всех регистров при JOIN_RP = 1
    wire [15:0] reg_pcr;                    // Шина регистра PCR
    wire [7:0]  alu_out;                    // Текущее состояние результата АЛУ
    wire        sel_data_read;              // Сигнал чтения данных с внешней шины на вход АЛУ или регистров
    wire        write_data;                 // Сигнал вывода данных на внешнюю шину DB
    wire        int_t2_del;                 // Сигнал подтверждения прерывания для такта после M1.T2
    wire        iff2;                       // Состояние триггера IFF2
    wire        empty_set_req;              // Сигнал запроса пустого набора команд
    wire        empty_set;                  // Сигнал пустого набора команд
    wire        grp_idx_cb;                 // Сигнал группы команд GRP_IDX_CB
    wire [7:0]  data_in_hold;               // Регистр фиксации данных, прочитанных с внешней шины
    wire        reset_c;                    // Сигнал сброса, синхронизированный с CLK
    wire        write_pcr;                  // Сигнал записи в PCR
    wire        sel_mask;                   // Сигнал генерации маски для BIT/RES/SET
    wire        int_stb;                    // Строб окончания текущей команды
    wire        int_req;                    // Сигнал запроса маскируемого прерывания
    wire        nmi_req;                    // Сигнал запроса немаскируемого прерывания
    // === SAVESTATE: дополнительные сигналы ===
    wire        iff1;                       // Триггер разрешения прерывания IFF1 (вынесен из Interrupt_logic)
    wire        im_bit0_out;                // Бит 0 режима IM (вынесен из Im_logic)
    wire        im_bit1_out;                // Бит 1 режима IM (вынесен из Im_logic)

    // === SAVESTATE: формирование save_int ===
    // Формат: биты [1:0] = IM, [2] = IFF1, [3] = IFF2, [7:4] = 0
    assign save_int = {4'b0000, iff2, iff1, im_bit1_out, im_bit0_out};

//----------------------------------------------------------------------
//
//                          Блок тестовой инициализации
//
//----------------------------------------------------------------------
    initial
    begin
    end

//----------------------------------------------------------------------
//
//                        Групповые декодеры
//
//----------------------------------------------------------------------
    Dec_dst_af dec_dst_af(                                              // Декодер группы команд для работы с регистром-приемником AF
        .pla(pla),
        .grp_dst_af(grp_dst_af)
    );

    Dec_m_hl dec_m_hl(                                                  // Декодер группы команд с адресацией (HL)
        .pla(pla),
        .grp_idx_cb(grp_idx_cb),
        .grp_m_hl(grp_m_hl)
    );

    Dec_n8 dec_n8(                                                      // Декодер группы команд, читающих байт непосредственных данных
        .pla(pla),
        .grp_imm8(grp_imm8)
    );

    Dec_mem_io dec_mem_io(                                              // Декодер группы команд, работающих с памятью/портами
        .pla(pla),
        .grp_a_mem_io(grp_a_mem_io)
    );

    Dec_sp dec_sp(                                                      // Декодер группы команд, работающих со стеком
        .pla(pla),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .grp_sp(grp_sp)
    );

    Dec_block dec_block(                                                // Декодер группы блочных команд
        .pla(pla),
        .grp_block(grp_block)
    );

    Dec_branch dec_branch(                                              // Декодер группы команд переходов
        .pla(pla),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .sel_im2(sel_im2),
        .grp_branch(grp_branch)
    );

    Dec_io dec_io(                                                      // Декодер группы команд ввода/вывода
        .t(t),
        .m(m),
        .pla(pla),
        .grp_io(grp_io)
    );

    Dec_offset dec_offset(                                              // Декодер группы команд, работающих с относительной адресацией
        .pla(pla),
        .cb_set(cb_set),
        .index_math(index_math),
        .grp_idx(grp_idx),
        .grp_offset_raw(grp_offset_raw)
    );

    Dec_wrdata dec_wrdata(                                              // Декодер группы команд, записывающих данные в память/порты
        .pla(pla),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .grp_wrdata(grp_wrdata)
    );

    Dec_m4 dec_m4(                                                      // Декодер группы команд, требующих цикл M4
        .pla(pla),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .grp_m4(grp_m4)
    );

    Dec_noalum1 dec_noalum1(                                            // Декодер группы команд, не требующих АЛУ в цикле M1
        .pla(pla),
        .grp_noalum1(grp_noalum1)
    );

    Dec_data16 dec_data16(                                              // Декодер группы команд для работы с 16-битными данными
        .pla(pla),
        .command(command),
        .grp_dir16(grp_dir16),
        .grp_branch(grp_branch),
        .grp_a_mem_io(grp_a_mem_io),
        .grp_sp(grp_sp),
        .grp_data16(grp_data16)
    );

    Dec_m3_not_last_raw dec_m3_not_last_raw(                            // Декодер группы команд, не заканчивающихся циклом M3
        .pla(pla),
        .sel_im2(sel_im2),
        .grp_idx_cb(grp_idx_cb),
        .grp_m3_not_last_raw(grp_m3_not_last_raw)
    );

    Dec_m3_t3_last dec_m3_t3_last(                                      // Декодер группы команд, заканчивающихся тактом M3.T3
        .pla(pla),
        .sel_im2(sel_im2),
        .grp_m3_t3_last(grp_m3_t3_last)
    );

    Dec_sel_acc dec_sel_acc(                                            // Декодер выбора аккумулятора по умолчанию
        .t(t),
        .m(m),
        .grp_idx(grp_idx),
        .grp_shift(grp_shift),
        .sel_acc(sel_acc)
    );

    Dec_reg_n dec_reg_n(                                                // Декодер выбора кода регистра
        .t(t),
        .pla(pla),
        .command(command),
        .cb_set(cb_set),
        .reg_n(reg_n)
    );

    Dec_reg_dst dec_reg_dst(                                            // Декодер группы команд, требующих регистр-приемник
        .pla(pla),
        .grp_reg_dst(grp_reg_dst)
    );

    Dec_reg_src dec_reg_src(                                            // Декодер запроса регистра-источника
        .t(t),
        .m(m),
        .pla(pla),
        .grp_m_hl(grp_m_hl),
        .cb_set(cb_set),
        .sel_reg_src(sel_reg_src)
    );

    Dec_reg_src_dst_r dec_reg_src_dst_r(                                // Декодер запроса регистра-источника/приемника или IR
        .t(t),
        .m(m),
        .pla(pla),
        .reg_n(reg_n),
        .sel_reg_src(sel_reg_src),
        .sel_reg_dst(sel_reg_dst),
        .sel_reg_src_r(sel_reg_src_r),
        .sel_reg_dst_r(sel_reg_dst_r)
    );

    Dec_imm dec_imm(                                                    // Декодер формирования сигналов GRP_IMM16 и GRP_IMM
        .pla(pla),
        .grp_idx_cb(grp_idx_cb),
        .grp_imm8(grp_imm8),
        .grp_idx(grp_idx),
        .idx_set(idx_set),
        .grp_imm16(grp_imm16),
        .grp_imm(grp_imm)
    );

//----------------------------------------------------------------------
//                    Компактные групповые декодеры
//----------------------------------------------------------------------
    // Группа команд записи/чтения регистровой пары по непосредственному адресу
    assign grp_dir16 = pla[30] |                                        // LD (nn),HL / LD HL,(nn)
                       pla[31];                                         // LD (nn),dd / LD dd,(nn)

    // Группа команд записи регистровой пары по непосредственному адресу
    assign grp_store16 = grp_dir16 & ~command[3];                       // LD (nn),dd

    // Группа команд сложения/вычитания с HL
    assign add_sub_hl = pla[69] |                                       // ADD HL,dd
                        pla[68];                                        // ADC HL,dd / SBC HL,dd

    // Группа команд LD(I/D)(R)/CP(I/D)(R)
    assign grp_ldi_cpi = pla[11] |                                      // CPI/CPD/CPIR/CPDR
                         pla[18];                                       // LDI/LDD/LDIR/LDDR

    // Группа команд, работающих с префиксами DD/FD/CB/ED
    assign grp_prefix = pla[3] |                                        // DD/FD prefix
                        pla[44] |                                       // CB prefix
                        pla[51];                                        // ED prefix

    // Группа команд, работающих со сдвигами
    assign grp_shift = pla[25] |                                        // RLCA/RRCA/RLA/RRA
                       pla[70];                                         // RLC/RRC/RL/RR/SLA/SRA/SLL/SRL

    // Группа команд с индексной адресацией
    assign grp_idx = idx_set &                                          // Набор команд DD/FD (индексная адресация)
                     grp_m_hl;                                          // Группа команд с адресацией (HL)

    assign save_flags = req_flags & sel_acc;                            // Сигнал записи флагов на FBUS
    assign load_flags = ~req_flags & sel_acc;                           // Сигнал сохранения текущих флагов с FBUS в кеше флагов
    assign sel_reg_dst = grp_reg_dst & m[1] & t[2];                     // Запрос регистра-приемника в такте M1.T2
    assign data_z = ~write_data;                                        // Сигнал перевода шины данных DATA_OUT в Z-состояние

//----------------------------------------------------------------------
//
//                      Подключение модулей
//
//----------------------------------------------------------------------
    Reset_logic reset_logic(                                            // Модуль формирования сигналов сброса
        .clk(clk),
        .reset(reset),
        .t(t),
        .m(m),
        .grp_prefix(grp_prefix),
        .reset_c(reset_c),                                              // Сигнал сброса, синхронизированный с CLK
        .sync_res(sync_res),                                            // Сигнал синхронного сброса
        .res(res),                                                      // Внутренний сигнал сброса, синхронен с /CLK
        .spec_res(spec_res)                                             // Сигнал специального сброса
    );

    Decoder decoder(                                                    // Модуль декодера команд
        .clk(clk),
        .t(t),
        .m(m),
        .data_in(data_in),
        .base_set(base_set),
        .ed_set(ed_set),
        .cb_set(cb_set),
        .idx_set(idx_set),
        .data_in_hold(data_in_hold),
        .command(command),                                              // Регистр команд COMMAND
        .pla(pla),                                                      // Шина ПЛМ
        .idx_cb(idx_cb)                                                 // Сигнал набора команд IDX CB
    );

    Dec_req_flags dec_req_flags(                                        // Модуль определяющий, влияет ли команда на флаги
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .sel_acc(sel_acc),
        .grp_dst_af(grp_dst_af),
        .req_flags(req_flags)                                           // Сигнал, определяющий, влияет ли команда на флаги
    );

    Idx_mode idx_mode(                                                  // Модуль режима вычисления индекса
        .clk(clk),
        .t(t),
        .m(m),
        .grp_idx(grp_idx),
        .grp_offset_raw(grp_offset_raw),
        .index_math(index_math)                                         // Сигнал, определяющий режим вычисления индекса
    );

    Bus_control #(
        .T2Write(T2Write)
    ) bus_control(                                            // Модуль управления внешней шиной
        .clk(clk),
        .res(res),
        .pla(pla),
        .m(m),
        .t(t),
        .grp_io(grp_io),
        .int_ack(int_ack),
        .dis_bus(dis_bus),
        .t1_stall(t1_stall),
        .int_t2_del(int_t2_del),
        .req_write(req_write),
        .reg_pcr(reg_pcr),
        .data_in(data_in),
        .hbus_in(hbus_in),
        .hbus_out(hbus_out),
        .sel_data_read(sel_data_read),
        .mreq(mreq),                                                    // Сигнал запроса памяти MREQ
        .iorq(iorq),                                                    // Сигнал запроса ввода-вывода IORQ
        .rd(rd),                                                        // Сигнал чтения памяти или портов ввода-вывода RD
        .wr(wr),                                                        // Сигнал записи в память или порт ввода-вывода WR
        .write_data(write_data),                                        // Сигнал вывода данных на внешнюю шину DB
        .data_in_hold(data_in_hold),                                    // Регистр фиксации данных
        .data_out(data_out),                                            // Шина данных (вывод)
        .p_m1(p_m1),                                                    // Сигнал машинного цикла M1
        .rfsh(rfsh),                                                    // Сигнал рефреша памяти RFSH
        .adr(adr),                                                      // Шина адреса (16 бит)
        .adr_z(adr_z)                                                   // Сигнал, переводящий шину адреса в Z-состояние
    );

    Register_selector register_selector(                                // Модуль выбора регистровой пары
        .clk(clk),
        .res(res),
        .pla(pla),
        .t(t),
        .m(m),
        .reg_n(reg_n),
        .sel_reg_src(sel_reg_src),
        .sel_reg_dst(sel_reg_dst),
        .sel_pc_src(sel_pc_src),
        .sel_pc_dst(sel_pc_dst),
        .sel_acc(sel_acc),
        .idx_set(idx_set),
        .grp_idx(grp_idx),
        .grp_wrdata(grp_wrdata),
        .grp_dst_af(grp_dst_af),
        .grp_block(grp_block),
        .grp_m_hl(grp_m_hl),
        .grp_sp(grp_sp),
        .grp_dir16(grp_dir16),
        .grp_store16(grp_store16),
        .add_sub_hl(add_sub_hl),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .sel_im2(sel_im2),
        .join_rp(join_rp),
        .sel_af(sel_af),
        .sel_af_(sel_af_),
        .sel_hl(sel_hl),
        .sel_hl_(sel_hl_),
        .sel_de(sel_de),
        .sel_de_(sel_de_),
        .sel_bc(sel_bc),
        .sel_bc_(sel_bc_),
        .sel_ix(sel_ix),
        .sel_iy(sel_iy),
        .sel_sp(sel_sp),
        .sel_wz(sel_wz),
        .sel_ir(sel_ir),
        .sel_pc(sel_pc)
    );

    Registers registers(                                                // Модуль банка регистров
        .clk(clk),
        .sel_af(sel_af),
        .sel_af_(sel_af_),
        .sel_hl(sel_hl),
        .sel_hl_(sel_hl_),
        .sel_de(sel_de),
        .sel_de_(sel_de_),
        .sel_bc(sel_bc),
        .sel_bc_(sel_bc_),
        .sel_ix(sel_ix),
        .sel_iy(sel_iy),
        .sel_sp(sel_sp),
        .sel_wz(sel_wz),
        .sel_ir(sel_ir),
        .sel_pc(sel_pc),
        .sel_acc(sel_acc),
        .join_rp(join_rp),
        .write_regh(write_regh),
        .write_regl(write_regl),
        .write_pcr(write_pcr),
        .read_regh(read_regh),
        .read_regl(read_regl),
        .data_in(data_in),                                              // Внешняя шина данных (ввод)
        .sel_data_read(sel_data_read),                                  // Сигнал чтения данных с внешней шины
        .hbus_in(hbus_in),                                              // Шина данных для записи в регистры, старшая часть
        .fbus_in(fbus_in),                                              // Шина данных для записи в регистры, младшая часть
        .pcrbus_in(pcrbus_in),                                          // Шина данных для записи в регистры IR и PC
        .hbus_out(hbus_out),                                            // Шина данных для чтения регистра, старшая часть
        .fbus_out(fbus_out),                                            // Шина данных для чтения регистра, младшая часть
        .pcrbus_out(pcrbus_out)                                         // Шина данных для чтения регистров IR и PC
    );

    Reg_readwrite reg_readwrite(                                        // Модуль управления чтением/записью регистров
        .t(t),
        .m(m),
        .pla(pla),
        .reg_n(reg_n),
        .sel_acc(sel_acc),
        .req_flags(req_flags),
        .grp_data16(grp_data16),
        .grp_wrdata(grp_wrdata),
        .grp_a_mem_io(grp_a_mem_io),
        .grp_offset_raw(grp_offset_raw),
        .grp_block(grp_block),
        .grp_dst_af(grp_dst_af),
        .add_sub_hl(add_sub_hl),
        .grp_store16(grp_store16),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .sel_im2(sel_im2),
        .sel_reg_dst_r(sel_reg_dst_r),
        .sel_reg_src_r(sel_reg_src_r),
        .write_regh(write_regh),
        .write_regl(write_regl),
        .read_regh(read_regh),
        .read_regl(read_regl)
    );

    PCR_unit pcr_unit(                                                  // Модуль 16-битного регистра-инкрементера PCR
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .res(res),
        .spec_res(spec_res),
        .command(command),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .sel_im2(sel_im2),
        .grp_sp(grp_sp),
        .grp_block(grp_block),
        .grp_wrdata(grp_wrdata),
        .grp_ldi_cpi(grp_ldi_cpi),
        .grp_offset_raw(grp_offset_raw),
        .grp_m_hl(grp_m_hl),
        .cond_done(cond_done),
        .sel_pc_src(sel_pc_src),
        .sel_pc_dst(sel_pc_dst),
        .pcrbus_out(pcrbus_out),
        .int_stop_pcr(int_stop_pcr),
        .res_tclk(res_tclk),
        .res_mclk(res_mclk),
        .write_pcr(write_pcr),                                          // Сигнал записи в PCR
        .pcr_equal_one(pcr_equal_one),                                  // Сигнал того, что PCR = 0x0001
        .join_rp(join_rp),                                              // Сигнал обьединения банков регистров
        .pcrbus_in(pcrbus_in),                                          // Шина данных для записи в регистры
        .reg_pcr(reg_pcr),                                              // Регистр PCR
        // === SAVESTATE ===
        .restore_pc(restore_pc),
        .restore_en(restore_en),
        .save_pc(save_pc)
    );

    Dec_dis_bus dec_dis_bus(                                            // Модуль управления запретом чтения/записи внешней шины
        .m(m),
        .pla(pla),
        .grp_offset_raw(grp_offset_raw),
        .grp_block(grp_block),
        .add_sub_hl(add_sub_hl),
        .grp_imm16(grp_imm16),
        .dis_bus(dis_bus)                                               // Сигнал запрета чтения/записи шины
    );

    Dec_pc_dst dec_pc_dst(                                              // Модуль декодера запроса PC приемником
        .t(t),
        .m(m),
        .res(res),
        .grp_imm16(grp_imm16),
        .grp_imm(grp_imm),
        .sel_pc_dst(sel_pc_dst)                                         // Сигнал выбора PC приемником
    );

    Dec_pc_src dec_pc_src(                                              // Модуль декодера запроса PC источником
        .m(m),
        .grp_branch(grp_branch),
        .grp_block(grp_block),
        .cond_done(cond_done),
        .res_tclk(res_tclk),
        .res_mclk(res_mclk),
        .grp_imm16(grp_imm16),
        .grp_imm(grp_imm),
        .sel_pc_src(sel_pc_src)                                         // Сигнал выбора PC источником
    );

    ALU_logic alu_logic(                                                // Модуль АЛУ
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .hbus_out(hbus_out),
        .fbus_out(fbus_out),
        .data_in(data_in),
        .data_out(data_out),
        .command(command),
        .cond(cond),
        .wr(wr),
        .sel_data_read(sel_data_read),
        .read_regh(read_regh),
        .read_regl(read_regl),
        .load_flags(load_flags),
        .req_flags(req_flags),
        .grp_noalum1(grp_noalum1),
        .grp_shift(grp_shift),
        .grp_reg_dst(grp_reg_dst),
        .grp_dst_af(grp_dst_af),
        .grp_offset_raw(grp_offset_raw),
        .grp_idx(grp_idx),
        .add_sub_hl(add_sub_hl),
        .cb_set(cb_set),
        .sel_nmi(sel_nmi),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .sel_im1(sel_im1),
        .sel_im2(sel_im2),
        .iff2(iff2),
        .pcr_equal_one(pcr_equal_one),
        .index_math(index_math),
        .sel_acc(sel_acc),
        .sel_mask(sel_mask),
        .flag_z(flag_z),
        .hbus_in(hbus_in),                                              // Шина данных для записи в регистры, старшая часть
        .fbus_in(fbus_in),                                              // Шина данных для записи в регистры, младшая часть
        .alu_out(alu_out)                                               // Текущее состояние результата АЛУ
    );

    MCycles_generator mcycles_generator(                                // Модуль генерации машинных M-циклов
        .clk(clk),
        .grp_m_hl(grp_m_hl),
        .grp_m4(grp_m4),
        .grp_imm8(grp_imm8),
        .idx_set(idx_set),
        .res_tclk(res_tclk),
        .res_mclk(res_mclk),
        .m(m)                                                           // Шина машинных циклов M1-M5
    );

    TCycles_generator tcycles_generator(                                // Модуль генерации T-циклов
        .clk(clk),
        .m(m),
        .t1_stall(t1_stall),
        .res_tclk(res_tclk),
        .int_ack(int_ack),
        .grp_io(grp_io),
        .dis_bus(dis_bus),
        .p_wait(p_wait),
        .int_t2_del(int_t2_del),                                        // Импульс длиной 1 такт для торможения цикла подтверждения прерывания
        .t(t)                                                           // Шина тактов T1-T6
    );

    TCycles_control tcycles_control(                                    // Модуль управления T-циклами
        .t(t),
        .m(m),
        .pla(pla),
        .res(res),
        .grp_offset_raw(grp_offset_raw),
        .grp_m3_t3_last(grp_m3_t3_last),
        .grp_m3_not_last_raw(grp_m3_not_last_raw),
        .grp_block(grp_block),
        .add_sub_hl(add_sub_hl),
        .cond_done(cond_done),
        .sel_im2(sel_im2),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .res_tclk(res_tclk)                                             // Сигнал сброса счета T-циклов
    );

    MCycles_control mcycles_control(                                    // Модуль управления машинными M-циклами
        .t(t),
        .m(m),
        .pla(pla),
        .res(res),
        .grp_m_hl(grp_m_hl),
        .grp_m4(grp_m4),
        .grp_imm8(grp_imm8),
        .grp_m3_not_last_raw(grp_m3_not_last_raw),
        .grp_idx(grp_idx),
        .grp_offset_raw(grp_offset_raw),
        .grp_m3_t3_last(grp_m3_t3_last),
        .cond_done(cond_done),
        .sel_im2(sel_im2),
        .res_mclk(res_mclk)                                             // Сигнал сброса счета машинных M-циклов
    );

    Dec_data_read dec_data_read(                                        // Модуль формирования сигнала чтения данных
        .t(t),
        .m(m),
        .pla(pla),
        .idx_cb(idx_cb),
        .dis_bus(dis_bus),
        .req_write(req_write),
        .sel_data_read(sel_data_read)                                   // Сигнал чтения данных с внешней шины
    );

    Dec_req_write dec_req_write(                                        // Модуль формирования сигнала запроса записи
        .m(m),
        .sel_im2(sel_im2),
        .grp_block(grp_block),
        .grp_wrdata(grp_wrdata),
        .grp_offset_raw(grp_offset_raw),
        .dis_bus(dis_bus),
        .req_write(req_write)                                           // Сигнал запроса записи
    );

    Condition_logic condition_logic(                                    // Модуль проверки условий
        .clk(clk),
        .m(m),
        .pla(pla),
        .command(command),
        .fbus_out(fbus_out),
        .reg_n(reg_n),
        .sel_acc(sel_acc),
        .grp_ldi_cpi(grp_ldi_cpi),
        .pcr_equal_one(pcr_equal_one),
        .flag_z(flag_z),
        .cond(cond),                                                    // Шина условий/декодера типа сдвига
        .cond_done(cond_done)                                           // Сигнал совпадения условия
    );

    Prefix_logic prefix_logic(                                          // Модуль префиксов
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .grp_idx(grp_idx),
        .idx_cb(idx_cb),
        .empty_set_req(empty_set_req),
        .res(res),
        .empty_set(empty_set),                                          // Сигнал пустого набора команд
        .base_set(base_set),                                            // Сигнал выбора базового набора
        .ed_set(ed_set),                                                // Сигнал выбора набора команд ED
        .cb_set(cb_set),                                                // Сигнал выбора набора команд CB
        .idx_set(idx_set),                                              // Сигнал выбора набора команд DD/FD
        .grp_idx_cb(grp_idx_cb),                                        // Сигнал группы команд GRP_IDX_CB
        .sel_mask(sel_mask)                                             // Сигнал генерации маски для BIT/RES/SET
    );

    Im_logic im_logic(                                                  // Модуль выбора режима IM
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .command(command),
        .sync_res(sync_res),
        .spec_res(spec_res),
        .reset_c(reset_c),
        .empty_set(empty_set),
        .int_ack(int_ack),
        .nmi_ack(nmi_ack),
        .halt(halt),
        .grp_prefix(grp_prefix),
        .int_stop_pcr(int_stop_pcr),                                    // Сигнал остановки счетчика PCR во время INT/HALT
        .sel_im1(sel_im1),                                              // Сигнал прерывания IM 1
        .sel_im2(sel_im2),                                              // Сигнал прерывания IM 2
        .sel_nmi(sel_nmi),                                              // Сигнал активного NMI
        .sel_rst_nmi_im1(sel_rst_nmi_im1),                              // Группа команд RST/NMI/IM 1
        .empty_set_req(empty_set_req),                                  // Сигнал запроса пустого набора команд
        // === SAVESTATE ===
        .restore_im(restore_int[1:0]),
        .restore_en(restore_en),
        .im_bit0_out(im_bit0_out),
        .im_bit1_out(im_bit1_out)
    );

    Interrupt_logic interrupt_logic(                                    // Модуль прерываний
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .command(command),
        .res_tclk(res_tclk),
        .res_mclk(res_mclk),
        .grp_prefix(grp_prefix),
        .res(res),
        .sync_res(sync_res),
        .p_int(p_int),
        .nmi(nmi),
        .int_stb(int_stb),                                              // Строб окончания текущей команды
        .int_req(int_req),                                              // Сигнал запроса маскируемого прерывания
        .int_ack(int_ack),                                              // Сигнал подтверждения маскируемого прерывания
        .nmi_ack(nmi_ack),                                              // Сигнал подтверждения немаскируемого прерывания
        .nmi_req(nmi_req),                                              // Сигнал запроса немаскируемого прерывания
        .iff2(iff2),                                                    // Триггер разрешения прерывания IFF2
        // === SAVESTATE ===
        .restore_iff(restore_int[3:2]),
        .restore_en(restore_en),
        .iff1(iff1)
    );

    Halt_logic halt_logic(                                              // Модуль останова HALT
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .reset_c(reset_c),
        .sync_res(sync_res),
        .int_req(int_req),
        .nmi_req(nmi_req),
        .int_stb(int_stb),
        .spec_res(spec_res),
        .halt(halt)                                                     // Сигнал HALT
    );

    Bus_request_logic bus_request_logic(                                // Модуль управления запросом шины
        .clk(clk),
        .res(res),
        .res_tclk(res_tclk),
        .busrq(busrq),
        .t1_stall(t1_stall),                                            // Сигнал задержки цикла T1
        .busack(busack),                                                // Сигнал предоставления доступа к шине
        .controls_z(controls_z)                                         // Сигнал перевода управляющих линий в z-состояние
    );

endmodule

//----------------------------------------------------------------------
//
//                           Модуль Decoder
//
//----------------------------------------------------------------------
module Decoder(
    input            clk,                                               // Тактовый сигнал
    input      [7:0] data_in,                                           // Внешняя шина данных (ввод)
    input      [6:1] t,                                                 // Такты
    input      [5:1] m,                                                 // Машинные циклы
    input            base_set,                                          // Сигнал выбора базового набора
    input            ed_set,                                            // Сигнал выбора набора ED
    input            cb_set,                                            // Сигнал выбора набора CB
    input            idx_set,                                           // Сигнал выбора набора DD/FD
    input      [7:0] data_in_hold,                                      // Регистр фиксации данных, прочитанных с внешней шины
    output reg [7:0] command,                                           // Регистр COMMAND
    output     [98:0] pla,                                              // Шина ПЛМ
    output           idx_cb                                             // Сигнал набора команд IDX CB
);
    wire        alu_set;                                                // Сигнал выбора типа АЛУ-операции основного набора
    wire [7:0]  mask_FF;                                                // Линии масок ПЛМ
    wire [7:0]  mask_FE;
    wire [7:0]  mask_F8;
    wire [7:0]  mask_F7;
    wire [7:0]  mask_F4;
    wire [7:0]  mask_E7;
    wire [7:0]  mask_E6;
    wire [7:0]  mask_DF;
    wire [7:0]  mask_CF;
    wire [7:0]  mask_CB;
    wire [7:0]  mask_C7;
    wire [7:0]  mask_C6;
    wire [7:0]  mask_C0;
    wire [7:0]  mask_38;
    wire [7:0]  mask_07;
    reg  [7:0]  command_pre;
    wire        idx_cb_mode;

//----------------------------------------------------------------------
    always @(posedge clk)                                               // Загрузка регистра кода команды по CLK
    begin
        if ((m[1] & t[3]) |                                             // Если такт M1.T3 (стандартная команда), или
            (idx_cb & t[4] & m[3]))                                     // Если такт M3.T4 и активен IDX_CB (команда DD/FD, CB), то
            command <= m[1] ? data_in : data_in_hold;                   // в такте M1 защелкиваются данные с шины данных
    end

//----------------------------------------------------------------------
    // Сигнал выбора АЛУ-операции основного набора
    assign alu_set = pla[64] |                                          // ALU n
                     pla[65];                                           // ALU r/(HL)

    assign mask_FF = command & 'hFF;                                    // Групповые маски ПЛМ
    assign mask_FE = command & 'hFE;
    assign mask_F8 = command & 'hF8;
    assign mask_F7 = command & 'hF7;
    assign mask_F4 = command & 'hF4;
    assign mask_E7 = command & 'hE7;
    assign mask_E6 = command & 'hE6;
    assign mask_DF = command & 'hDF;
    assign mask_CF = command & 'hCF;
    assign mask_CB = command & 'hCB;
    assign mask_C7 = command & 'hC7;
    assign mask_C6 = command & 'hC6;
    assign mask_C0 = command & 'hC0;
    assign mask_38 = command & 'h38;
    assign mask_07 = command & 'h07;

    // ПЛМ базового набора команд
    assign pla[3]   = base_set & (mask_DF == 'hDD);                     // DD/FD prefix
    assign pla[44]  = base_set & (mask_FF == 'hCB);                     // CB prefix
    assign pla[51]  = base_set & (mask_FF == 'hED);                     // ED prefix
    assign pla[1]   = base_set & (mask_FF == 'hD9);                     // EXX
    assign pla[2]   = base_set & (mask_FF == 'hEB);                     // EX DE,HL
    assign pla[39]  = base_set & (mask_FF == 'h08);                     // EX AF,AF'
    assign pla[5]   = base_set & (mask_FF == 'hF9);                     // LD SP,HL
    assign pla[10]  = base_set & (mask_FF == 'hE3);                     // EX (SP),HL
    assign pla[6]   = base_set & (mask_FF == 'hE9);                     // JP (HL)
    assign pla[77]  = base_set & (mask_FF == 'h27);                     // DAA
    assign pla[81]  = base_set & (mask_FF == 'h2F);                     // CPL
    assign pla[89]  = base_set & (mask_FF == 'h3F);                     // CCF
    assign pla[92]  = base_set & (mask_FF == 'h37);                     // SCF
    assign pla[95]  = base_set & (mask_FF == 'h76);                     // HALT
    assign pla[97]  = base_set & (mask_F7 == 'hF3);                     // EI/DI
    assign pla[98]  = base_set & (mask_F7 == 'hD3);                     // OUT (n),A / IN A,(n)
    assign pla[28]  = base_set & (mask_FF == 'hD3);                     // OUT (n),A
    assign pla[26]  = base_set & (mask_FF == 'h10);                     // DJNZ e
    assign pla[47]  = base_set & (mask_FF == 'h18);                     // JR e
    assign pla[48]  = base_set & (mask_E7 == 'h20);                     // JR NZ/Z/NC/C,e
    assign pla[29]  = base_set & (mask_FF == 'hC3);                     // JP nn
    assign pla[43]  = base_set & (mask_C7 == 'hC2);                     // JP cc,nn
    assign pla[24]  = base_set & (mask_FF == 'hCD);                     // CALL nn
    assign pla[42]  = base_set & (mask_C7 == 'hC4);                     // CALL cc,nn
    assign pla[56]  = base_set & (mask_C7 == 'hC7);                     // RST p
    assign pla[35]  = base_set & (mask_FF == 'hC9);                     // RET
    assign pla[45]  = base_set & (mask_C7 == 'hC0);                     // RET cc
    assign pla[25]  = base_set & (mask_E7 == 'h07);                     // RLCA/RRCA/RLA/RRA
    assign pla[40]  = base_set & (mask_FF == 'h36);                     // LD (HL),A
    assign pla[38]  = base_set & (mask_F7 == 'h32);                     // LD (nn),A / A,(nn)
    assign pla[30]  = base_set & (mask_F7 == 'h22);                     // LD (nn),HL / LD HL,(nn)
    assign pla[8]   = base_set & (mask_E7 == 'h02);                     // LD (BC/DE),A / LD A,(BC/DE)
    assign pla[13]  = base_set & (mask_CF == 'h02);                     // LD (BC/DE),A / LD (nn),HL / LD (nn),A
    assign pla[7]   = base_set & (mask_CF == 'h01);                     // LD BC/DE/HL/SP,nn
    assign pla[69]  = base_set & (mask_CF == 'h09);                     // ADD HL,BC/DE/HL/SP
    assign pla[9]   = base_set & (mask_C7 == 'h03);                     // DEC BC/DE/HL/SP / INC BC/DE/HL/SP
    assign pla[14]  = base_set & (mask_CF == 'h0B);                     // DEC BC/DE/HL/SP
    assign pla[66]  = base_set & (mask_C6 == 'h04);                     // INC/DEC B/C/D/E/H/L/(HL)/A
    assign pla[75]  = base_set & (mask_C7 == 'h05);                     // DEC B/C/D/E/H/L/(HL)/A
    assign pla[53]  = base_set & (mask_FE == 'h34);                     // INC/DEC (HL)
    assign pla[23]  = base_set & (mask_CB == 'hC1);                     // PUSH BC/DE/HL/AF / POP BC/DE/HL/AF
    assign pla[16]  = base_set & (mask_CF == 'hC5);                     // PUSH BC/DE/HL/AF
    assign pla[17]  = base_set & (mask_C7 == 'h06);                     // LD B/C/D/E/H/L/(HL)/A,n
    assign pla[58]  = base_set & (mask_C7 == 'h46) & ~pla[95];          // LD B/C/D/E/H/L/A,(HL)
    assign pla[59]  = base_set & (mask_F8 == 'h70) & ~pla[95];          // LD (HL),B/C/D/E/H/L/A
    assign pla[52]  = base_set & (mask_C7 == 'h86);                     // ADD/ADC/SUB/SBC/AND/XOR/OR/CP (HL)
    assign pla[64]  = base_set & (mask_C7 == 'hC6);                     // ADD/ADC/SUB/SBC/AND/XOR/OR/CP n
    assign pla[61]  = base_set & (mask_C0 == 'h40);                     // 01xxxxxx LD
    assign pla[65]  = base_set & (mask_C0 == 'h80);                     // 10xxxxxx ALU

    // ПЛМ базового набора команд АЛУ
    assign pla[84]  = alu_set & (mask_38 == 'h00);                      // xx000xxx - ADD
    assign pla[78]  = alu_set & (mask_38 == 'h10);                      // xx010xxx - SUB
    assign pla[76]  = alu_set & (mask_38 == 'h38);                      // xx111xxx - CP
    assign pla[80]  = alu_set & (mask_38 == 'h08);                      // xx001xxx - ADC
    assign pla[79]  = alu_set & (mask_38 == 'h18);                      // xx011xxx - SBC
    assign pla[85]  = alu_set & (mask_38 == 'h20);                      // xx100xxx - AND
    assign pla[88]  = alu_set & (mask_38 == 'h28);                      // xx101xxx - XOR
    assign pla[86]  = alu_set & (mask_38 == 'h30);                      // xx110xxx - OR

    // ПЛМ набора команд ED
    assign pla[4]   = ed_set & (mask_E7 == 'h47);                       // LD A,I/R / LD I/R,A
    assign pla[87]  = ed_set & (mask_F7 == 'h57);                       // LD A,I/R
    assign pla[57]  = ed_set & (mask_F7 == 'h47);                       // LD I/R,A
    assign pla[96]  = ed_set & (mask_C7 == 'h46);                       // IM 0/1/2
    assign pla[82]  = ed_set & (mask_C7 == 'h44);                       // NEG
    assign pla[60]  = ed_set & (mask_F7 == 'h67);                       // RRD/RLD
    assign pla[46]  = ed_set & (mask_C7 == 'h45);                       // RETN/RETI
    assign pla[31]  = ed_set & (mask_C7 == 'h43);                       // LD (nn),BC/DE/HL/SP / LD BC/DE/HL/SP,(nn)
    assign pla[37]  = ed_set & (mask_CF == 'h43);                       // LD (nn),BC/DE/HL/SP
    assign pla[68]  = ed_set & (mask_C7 == 'h42);                       // ADC HL,BC/DE/HL/SP / SBC HL,BC/DE/HL/SP
    assign pla[27]  = ed_set & (mask_C6 == 'h40);                       // IN B/C/D/E/H/L/F/A,(C) / OUT (C),B/C/D/E/H/L/0/A
    assign pla[67]  = ed_set & (mask_C7 == 'h40);                       // IN B/C/D/E/H/L/F/A,(C)
    assign pla[34]  = ed_set & (mask_C7 == 'h41);                       // OUT (C),B/C/D/E/H/L/0/A
    assign pla[0]   = ed_set & (mask_F4 == 'hA0);                       // LDI/CPI/INI/OUTI / LDD/CPD/IND/OUTD
    assign pla[18]  = ed_set & (mask_E7 == 'hA0);                       // LDI/LDD/LDIR/LDDR
    assign pla[11]  = ed_set & (mask_E7 == 'hA1);                       // CPI/CPD/CPIR/CPDR
    assign pla[91]  = ed_set & (mask_E6 == 'hA2);                       // INI/IND/INIR/INDR / OUTI/OUTD/OTIR/OTDR
    assign pla[21]  = ed_set & (mask_E7 == 'hA2);                       // INI/IND/INIR/INDR
    assign pla[20]  = ed_set & (mask_E7 == 'hA3);                       // OUTI/OUTD/OTIR/OTDR

    // ПЛМ набора команд CB
    assign pla[70]  = cb_set & (mask_C0 == 'h00);                       // RLC/RRC/RL/RR/SLA/SRA/SLL/SRL
    assign pla[72]  = cb_set & (mask_C0 == 'h40);                       // BIT
    assign pla[73]  = cb_set & (mask_C0 == 'h80);                       // RES
    assign pla[74]  = cb_set & (mask_C0 == 'hC0);                       // SET
    assign pla[55]  = cb_set & (mask_07 == 'h06);                       // RLC/RRC/RL/RR/SLA/SRA/SLL/SRL/BIT/RES/SET (HL)
    assign idx_cb   = idx_set & (mask_FF == 'hCB);                      // ПЛМ набора команд IDX CB

endmodule

//----------------------------------------------------------------------
//
//                  Модуль управления внешней шиной
//
//----------------------------------------------------------------------
module Bus_control #(
    parameter T2Write = 1  // 0 => WR_n active in T3 (standard NMOS), 1 => WR_n active in T2 (early write)
)(
    input             clk,                                      // Тактовый сигнал
    input             res,                                      // Сигнал сброса
    input [98:0]      pla,                                      // Шина ПЛМ
    input [6:1]       t,                                        // Такты
    input [5:1]       m,                                        // Машинные циклы
    input             grp_io,                                   // Сигнал GRP_IO
    input             int_ack,                                  // Сигнал INT_ACK
    input             dis_bus,                                  // Сигнал DIS_BUS
    input             t1_stall,                                 // Сигнал T1_STALL
    input             int_t2_del,                               // Сигнал INT_T2_DEL
    input             req_write,                                // Сигнал запроса записи
    input [15:0]      reg_pcr,                                  // Регистр PCR
    input [7:0]       data_in,                                  // Внешняя шина данных (ввод)
    input [7:0]       hbus_in,                                  // Шина данных для записи в регистры HBUS_IN
    input [7:0]       hbus_out,                                 // Шина данных для чтения регистров, старшая часть HBUS_OUT
    input             sel_data_read,                            // Сигнал чтения данных с внешней шины на вход АЛУ или регистров
    output            mreq,                                     // Сигнал запроса памяти MREQ
    output            iorq,                                     // Сигнал запроса ввода-вывода IORQ
    output            rd,                                       // Сигнал чтения памяти или портов ввода-вывода RD
    output            wr,                                       // Сигнал записи в память и порт ввода-вывода WR
    output            write_data,                               // Сигнал вывода данных на внешнюю шину DB (снятие Z-состояния с выходного порта)
    output reg [7:0]  data_in_hold,                             // Регистр фиксации данных, прочитанных с внешней шины
    output reg [7:0]  data_out,                                 // Шина данных (вывод)
    output reg        p_m1,                                     // Сигнал машинного цикла M1
    output reg        rfsh,                                     // Сигнал рефреша памяти RFSH
    output reg [15:0] adr,                                      // Шина адреса (16 бит)
    output reg        adr_z                                     // Сигнал, переводящий шину адреса в Z-состояние
);

    wire    sel_data_write;                                     // Сигнал записи данных на внешнюю шину
    reg     write_data_pre;                                     // Триггер записи данных на внешнюю шину DB
    reg     write_data_stb;                                     // Триггер строба начала записи данных
    reg     t1_del;                                             // Такт T1, задержанный на полтакта
    reg     t3_del;                                             // Такт T3, задержанный на полтакта
    wire    rw_data_start;                                      // Промежуточные групповые сигналы
    wire    io_start;
    wire    common_stop;
    wire    trunc_io_front;
    reg     mreq_wr_rs;                                         // Триггеры для формирования промежуточных сигналов
    reg     mreq_op_rs;
    reg     read_io_rs;
    reg     iorq_rs;
    reg     write_rs;

//------------------------------------------------------------------
// Формирование сигнала WRITE_DATA (вывода данных на внешнюю шину DB)
// Данные всегда выставляются в T1, независимо от T2Write
//------------------------------------------------------------------
    assign sel_data_write = req_write & t[1];                   // Если такт T1 и REQ_WRITE, то установить сигнал записи

    always @(posedge clk)                                       // Синхронизация останова по CLK
    begin
        if (t1_stall | t[1])
            write_data_pre <= 0;
        else if (write_data_stb)
            write_data_pre <= 1;
    end

    always @(negedge clk)                                       // Синхронизация старта по /CLK
    begin
        write_data_stb <= sel_data_write;
    end

    assign write_data = write_data_pre | write_data_stb;

//------------------------------------------------------------------
    always @(posedge clk)                                       // Формирование вспомогательных циклов T1 и T3, сдвинутых на полтакта
    begin
        t1_del <= t[1];
        t3_del <= t[3];
    end

//------------------------------------------------------------------
    assign rw_data_start = t[1] & ~m[1] & ~grp_io & ~dis_bus;   // Сигнал старта цикла чтения/записи
    assign io_start = t[1] & grp_io;                            // Сигнал старта цикла ввода-вывода
    assign common_stop = t[3] | res;                            // Сигнал останова циклов
    assign trunc_io_front = t1_del & grp_io;                    // Обрезка фронта для сигналов ввода-вывода

//------------------------------------------------------------------
// Групповые триггеры с поддержкой T2Write
//------------------------------------------------------------------
    always @(negedge clk)
    begin
        // MREQ_WR_RS: запрос памяти для чтения/записи
        if ((t[3] & ~m[1]) | t[4] | res)
            mreq_wr_rs <= 0;
        else if ((m[1] & t[3]) | rw_data_start)
            mreq_wr_rs <= 1;

        // MREQ_OP_RS: запрос памяти для чтения опкода
        if (common_stop)
            mreq_op_rs <= 0;
        else if (t[1] & m[1] & ~int_ack)
            mreq_op_rs <= 1;

        // READ_IO_RS: запрос чтения
        if (common_stop)
            read_io_rs <= 0;
        else if ((rw_data_start | io_start) & ~req_write)
            read_io_rs <= 1;

        // IORQ_RS: запрос ввода-вывода
        if (common_stop)
            iorq_rs <= 0;
        else if (io_start | int_t2_del)
            iorq_rs <= 1;

        // WRITE_RS: запрос записи с учётом T2Write
        if (common_stop)
            write_rs <= 0;
        else if (T2Write) begin
            // T2Write=1: WR_n активен начиная с T2 для всех операций записи
            // (и память, и I/O стартуют с T1, WR активен с T2)
            if (t[1] & req_write)
                write_rs <= 1;
        end else begin
            // T2Write=0: стандартное поведение NMOS Z80
            // I/O: WR активен с T2 (старт в T1)
            // Memory: WR активен с T3 (старт в T2)
            if ((t[1] & grp_io & req_write) | (t[2] & req_write))
                write_rs <= 1;
        end
    end

//------------------------------------------------------------------
// Обьединение сигналов с групповых триггеров
//------------------------------------------------------------------
    assign mreq = mreq_wr_rs | (mreq_op_rs & ~t3_del);
    assign rd   = (mreq_op_rs & ~t3_del) | (read_io_rs & ~trunc_io_front);
    assign iorq = iorq_rs & ~trunc_io_front & ~(t3_del & m[1]);
    assign wr   = write_rs & ~trunc_io_front;

//------------------------------------------------------------------
    always @(posedge clk)
    begin
        // Управление портом M1
        if (t[3] | t1_stall)
            p_m1 <= 0;
        else if (m[1] & t[1])
            p_m1 <= 1;

        // Управление портом RFSH
        rfsh <= m[1] & (t[3] | t[4]);

        // Управление шиной адреса AD
        if (((m[1] & t[3]) | t[1]) & ~dis_bus)
            adr <= reg_pcr;

        // Управление Z-состоянием шины адреса
        adr_z <= t1_stall;
    end

//------------------------------------------------------------------
    always @(negedge clk)
    begin
        if (t[3])
            data_in_hold <= data_in;

        if (sel_data_write)
            data_out <= (pla[17] ? data_in_hold : (hbus_in | hbus_out));
    end

endmodule

//----------------------------------------------------------------------
//
//                  Модуль формирования сигналов сброса
//
//----------------------------------------------------------------------
module Reset_logic(
    input       clk,                                                    // Тактовый сигнал
    input       reset,                                                  // Сигнал внешнего сброса
    input [6:1] t,                                                      // Такты
    input [5:1] m,                                                      // Машинные циклы
    input       grp_prefix,                                             // Группа команд с префиксом
    output reg  reset_c,                                                // Сигнал сброса, синхронизированный с CLK
    output reg  sync_res,                                               // Сигнал синхронного сброса
    output reg  res,                                                    // Внутренний сигнал сброса, синхронен с /CLK
    output      spec_res                                                // Сигнал специального сброса
);
    reg spec_res_reg;                                                   // Триггер синхронного сброса

//----------------------------------------------------------------------
    always @(posedge clk)                                               // Формирование синхронных сигналов сброса по CLK
    begin
        reset_c <= reset;                                               // RESET_C - внешний сигнал сброса
        if (~(m[1] & t[2]))                                             // SYNC_RES - внешний сигнал сброса, кроме такта M1.T2
            sync_res <= reset;
    end

    always @(negedge clk)                                               // Формирование внутреннего сигнала сброса по /CLK
    begin
        res <= sync_res;                                                // RES - сигнал SYNC_RES, задержанный на полтакта
    end

    always @(negedge clk)                                               // Формирование сигнала специального сброса по /CLK
    begin
        if (sync_res)                                                   // Если сброс
            spec_res_reg <= 0;
        else if ((reset_c | ~grp_prefix) & t[2] & m[1])                 // Иначе, если цикл M1.T2
            spec_res_reg <= reset_c;
    end

    assign spec_res = spec_res_reg & ~grp_prefix;                       // Итоговый сигнал специального сброса

endmodule

//----------------------------------------------------------------------
//
//                     Модули групповых декодеров
//
//----------------------------------------------------------------------
module Dec_dst_af(                                                      // Декодер группы команд для работы с регистром-приемником AF
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        grp_dst_af                                            // Сигнал группы команд для работы с регистром-приемником AF
);
    // Группа команд для работы с регистром-приемником AF
    assign grp_dst_af = (pla[65] |                                      // ALU
                         pla[64] |                                      // ALU n
                         pla[87] |                                      // LD A,I/R
                         pla[81] |                                      // CPL
                         pla[82] |                                      // NEG
                         pla[77] |                                      // DAA
                         pla[25] |                                      // RLCA/RRCA/RLA/RRA
                         pla[60]) & ~pla[76];                           // RRD/RLD (кроме команды CP)
endmodule

//----------------------------------------------------------------------
module Dec_m_hl(                                                        // Декодер группы команд с адресацией (HL)
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         grp_idx_cb,                                           // Сигнал группы команд GRP_IDX_CB
    output        grp_m_hl                                              // Сигнал группы команд с адресацией (HL)
);
    // Группа команд с адресацией (HL)
    assign grp_m_hl = pla[52] |                                         // ALU (HL)
                      pla[58] |                                         // LD r,(HL)
                      pla[59] |                                         // LD (HL),r
                      pla[40] |                                         // LD (HL),n
                      pla[53] |                                         // INC/DEC (HL)
                      pla[55] |                                         // RLC/RRC/RL/RR/SLA/SRA/SLL/SRL/BIT/RES/SET (HL)
                      grp_idx_cb;                                       // IDX CB SET
endmodule

//----------------------------------------------------------------------
module Dec_n8(                                                          // Декодер группы команд, читающих байт непосредственных данных
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        grp_imm8                                              // Сигнал группы команд, читающих один байт непосредственных данных
);
    assign grp_imm8 = pla[64] |                                         // ALU n
                      pla[47] |                                         // JR e
                      pla[26] |                                         // DJNZ e
                      pla[48] |                                         // JR NZ/Z/NC/C,e
                      pla[17] |                                         // LD r/(HL),n
                      pla[98];                                          // OUT (n),A / IN A,(n)
endmodule

//----------------------------------------------------------------------
module Dec_mem_io(                                                      // Декодер группы команд, работающих с памятью/портами
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        grp_a_mem_io                                          // Сигнал группы команд, работающих с памятью/портами
);
    assign grp_a_mem_io = pla[8]  |                                     // LD (BC/DE),A / LD A,(BC/DE)
                          pla[38] |                                     // LD A,(nn) / LD (nn),A
                          pla[98];                                      // OUT (n),A / IN A,(n)
endmodule

//----------------------------------------------------------------------
module Dec_sp(                                                          // Декодер группы команд, работающих со стеком
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         sel_rst_nmi_im1,                                      // Группа команд RST/NMI/IM 1
    output        grp_sp                                                // Сигнал группы команд, работающих со стеком
);
    assign grp_sp = pla[35] |                                           // RET
                    pla[45] |                                           // RET cc
                    pla[46] |                                           // RETN/RETI
                    pla[24] |                                           // CALL nn
                    pla[42] |                                           // CALL cc,nn
                    pla[10] |                                           // EX (SP),HL
                    pla[23] |                                           // POP dd / PUSH dd
                    sel_rst_nmi_im1;
endmodule

//----------------------------------------------------------------------
module Dec_block(                                                       // Декодер группы блочных команд
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        grp_block                                             // Сигнал группы блочных команд
);
    assign grp_block = pla[18] |                                        // LDI/LDD/LDIR/LDDR
                       pla[11] |                                        // CPI/CPD/CPIR/CPDR
                       pla[21] |                                        // INI/IND/INIR/INDR
                       pla[20];                                         // OUTI/OUTD/OTIR/OTDR
endmodule

//----------------------------------------------------------------------
module Dec_branch(                                                      // Декодер группы команд переходов
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         sel_rst_nmi_im1,                                      // Группа команд RST/NMI/IM 1
    input         sel_im2,                                              // Сигнал прерывания IM 2
    output        grp_branch                                            // Сигнал группы команд переходов
);
    assign grp_branch = pla[47] |                                       // JR e
                        pla[48] |                                       // JR NZ/Z/NC/C,e
                        pla[26] |                                       // DJNZ e
                        pla[29] |                                       // JP nn
                        pla[43] |                                       // JP cc,nn
                        pla[6]  |                                       // JP (HL)
                        pla[24] |                                       // CALL nn
                        pla[42] |                                       // CALL cc,nn
                        pla[35] |                                       // RET
                        pla[45] |                                       // RET cc
                        pla[46] |                                       // RETN/RETI
                        sel_im2 |
                        sel_rst_nmi_im1;
endmodule

//----------------------------------------------------------------------
module Dec_io(                                                          // Декодер группы команд ввода/вывода
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        grp_io                                                // Сигнал группы команд ввода/вывода
);
    assign grp_io = (pla[21] & m[2]) |                                  // INI/IND/INIR/INDR
                    (pla[20] & m[3]) |                                  // OUTI/OUTD/OTIR/OTDR
                    ((pla[27] | pla[98]) & m[4]);                       // IN r,(C) / OUT (C),r / OUT (n),A / IN A,(n)
endmodule

//----------------------------------------------------------------------
module Dec_offset(                                                      // Декодер группы команд, работающих с относительной адресацией
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         cb_set,                                               // Набор команд с префиксом CB
    input         index_math,                                           // Режим вычисления индекса
    input         grp_idx,                                              // Группа команд с индексной адресацией
    output        grp_offset_raw                                        // Сигнал группы команд, работающих с относительной адресацией
);
    assign grp_offset_raw = pla[47] |                                   // JR e
                            pla[48] |                                   // JR NZ/Z/NC/C,e
                            pla[26] |                                   // DJNZ e
                            pla[66] |                                   // INC/DEC r/(HL)
                            pla[91] |                                   // INI/OUTI/IND/OUTD / INIR/OTIR/INDR/OTDR
                            cb_set |
                            (grp_idx & index_math);
endmodule

//----------------------------------------------------------------------
module Dec_wrdata(                                                      // Декодер группы команд, записывающих данные в память/порты
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         sel_rst_nmi_im1,                                      // Группа команд RST/NMI/IM 1
    output        grp_wrdata                                            // Сигнал группы команд, записывающих данные в память/порты
);
    assign grp_wrdata = pla[59] |                                       // LD (HL),r
                        pla[40] |                                       // LD (HL),n
                        pla[37] |                                       // LD (nn),dd
                        pla[13] |                                       // LD (BC/DE),A / LD (nn),HL / LD (nn),A
                        pla[9]  |                                       // INC dd / DEC dd
                        pla[5]  |                                       // LD SP,HL
                        pla[10] |                                       // EX (SP),HL
                        pla[16] |                                       // PUSH dd
                        pla[24] |                                       // CALL nn
                        pla[42] |                                       // CALL cc,nn
                        pla[28] |                                       // OUT (n),A
                        pla[34] |                                       // OUT (C), r
                        pla[60] |                                       // RRD/RLD
                        sel_rst_nmi_im1;
endmodule

//----------------------------------------------------------------------
module Dec_m4(                                                          // Декодер группы команд, требующих цикл M4
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         sel_rst_nmi_im1,                                      // Группа команд RST/NMI/IM 1
    output        grp_m4                                                // Сигнал группы команд, требующих цикл M4
);
    assign grp_m4 = pla[40] |                                           // LD (HL),n
                    pla[8]  |                                           // LD (BC/DE),A / LD A,(BC/DE)
                    pla[69] |                                           // ADD HL,dd
                    pla[68] |                                           // SBC HL,dd / ADC HL,dd
                    pla[23] |                                           // POP dd / PUSH dd
                    pla[35] |                                           // RET
                    pla[45] |                                           // RET cc
                    pla[46] |                                           // RETN/RETI
                    pla[27] |                                           // IN r,(C) / OUT (C),r
                    pla[98] |                                           // OUT (n),A / IN A,(n)
                    sel_rst_nmi_im1;
endmodule

//----------------------------------------------------------------------
module Dec_noalum1(                                                     // Декодер группы команд, не требующих АЛУ в цикле M1
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        grp_noalum1                                           // Сигнал группы команд, не требующих АЛУ в цикле M1
);
    assign grp_noalum1 = pla[89] |                                      // CCF
                         pla[92] |                                      // SCF
                         pla[91] |                                      // INI/OUTI/IND/OUTD / INIR/OTIR/INDR/OTDR
                         pla[11] |                                      // CPI/CPD/CPIR/CPDR
                         pla[18];                                       // LDI/LDD/LDIR/LDDR
endmodule

//----------------------------------------------------------------------
module Dec_data16(                                                      // Декодер группы команд для работы с 16-битными данными
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0]  command,                                              // Регистр COMMAND
    input         grp_dir16,                                            // Группа команд записи/чтения регистровой пары по непосредственному адресу
    input         grp_branch,                                           // Группа команд переходов
    input         grp_a_mem_io,                                         // Группа команд, работающих с памятью/портами
    input         grp_sp,                                               // Группа команд, работающих со стеком
    output        grp_data16                                            // Группа команд для работы с 16-битными данными
);
    assign grp_data16 = (~(pla[26] | pla[47] | pla[48]) & grp_branch) | // Absolute branch
                        (grp_dir16 & command[3]) |                      // LD (nn),dd / LD dd,(nn)
                        pla[7]  |                                       // LD dd,nn
                        pla[23] |                                       // POP dd / PUSH dd
                        grp_a_mem_io |
                        grp_sp;
endmodule

//----------------------------------------------------------------------
module Dec_sel_acc(                                                     // Декодер выбора аккумулятора по умолчанию
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input         grp_idx,                                              // Группа команд с индексной адресацией
    input         grp_shift,                                            // Группа команд сдвигов
    output        sel_acc                                               // Сигнал выбора аккумулятора по умолчанию
);
    // Сигнал выбора аккумулятора по умолчанию
    assign sel_acc = (m[1] & t[3]) |                                    // По M1.T3 - для любой команды
                     (m[4] & t[2] & (grp_shift | grp_idx));             // По M4.T2 - для команд сдвига или индексной адресации
endmodule

//----------------------------------------------------------------------
module Dec_reg_n(                                                       // Декодер выбора кода регистра
    input  [6:1]  t,                                                    // Такты
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0]  command,                                              // Регистр COMMAND
    input         cb_set,                                               // Набор команд с префиксом CB
    output [2:0]  reg_n                                                 // Трехбитный код регистровой пары
);
    assign reg_n = (pla[65] |                                           // Для команд ALU,
                    cb_set  |                                           // Группы CB и
                    (pla[61] & ~t[2])) ?                                // LD (кроме такта T2)
                   command[2:0] :                                       // Номер регистра извлекается из битов [2:0]
                   command[5:3];                                        // Номер регистра извлекается из битов [5:3]
endmodule

//----------------------------------------------------------------------
module Dec_reg_dst(                                                     // Декодер группы команд, требующих регистр-приемник
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        grp_reg_dst                                           // Сигнал группы команд, требующих регистр-приемник
);
    assign grp_reg_dst = pla[61] |                                      // LD
                         pla[17] |                                      // LD r/(HL),n
                         pla[66] |                                      // INC/DEC
                         pla[70] |                                      // SHIFT
                         pla[73] |                                      // RES
                         pla[74] |                                      // SET
                         pla[67];                                       // IN r,(C)
endmodule

//----------------------------------------------------------------------
module Dec_req_alua(                                                    // Модуль формирования сигнала запроса ALUA
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input         sel_acc,                                              // Сигнал выбора аккумулятора по умолчанию
    input         add_sub_hl,                                           // Группа команд сложения/вычитания с HL
    input         grp_offset_raw,                                       // Группа команд, работающих с относительной адресацией
    input         grp_idx,                                              // Группа команд с индексной адресацией
    input         sel_im2,                                              // Сигнал прерывания IM 2
    output        req_alua                                              // Сигнал запроса ALUA
);
    assign req_alua = ((grp_offset_raw | add_sub_hl) & m[1] & t[4]) |
                      ((grp_offset_raw | grp_idx) & m[2] & t[2]) |      // Low byte add of index pointer
                      ((m[3] | (m[4] & ~pla[91])) & t[3] & grp_offset_raw) | // High byte add of index pointer
                      (m[4] & t[4] & add_sub_hl) |                      // High byte of 16-bit add
                      (m[1] & t[5] & sel_im2) |
                      sel_acc;
endmodule

//----------------------------------------------------------------------
module Dec_req_alub1(                                                   // Модуль формирования сигнала запроса ALUB1
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input         add_sub_hl,                                           // Группа команд сложения/вычитания с HL
    input         grp_idx,                                              // Группа команд с индексной адресацией
    input         sel_rst_nmi_im1,                                      // Группа команд RST/NMI/IM 1
    output        req_alub1                                             // Сигнал запроса ALUB1
);
    assign req_alub1 = ((m[1] | m[2]) & t[3]) |                         // standard ALU cycle
                       ((add_sub_hl | grp_idx) & m[4] & t[1]) |         // Low byte of 16-bit add
                       (m[5] & t[1] & add_sub_hl) |                     // High byte of 16-bit add
                       (m[1] & t[5] & sel_rst_nmi_im1);
endmodule

//----------------------------------------------------------------------
module Dec_req_alub2(                                                   // Модуль формирования сигнала запроса ALUB2
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        req_alub2                                             // Сигнал запроса ALUB2
);
    wire grp_alub2;
    assign grp_alub2 = pla[61] |                                        // LD
                       pla[87] |                                        // LD A,I/R
                       pla[17] |                                        // LD r/(HL),n
                       pla[65] |                                        // ALU
                       pla[64] |                                        // ALU n
                       pla[25] |                                        // RLCA/RRCA/RLA/RRA
                       pla[70] |                                        // RLC/RRC/RL/RR/SLA/SRA/SLL/SRL
                       pla[77] |                                        // DAA
                       pla[67];                                         // IN r,(C)
    assign req_alub2 = (grp_alub2 & m[1] & t[4]) |                      // standard ALU cycle
                       (grp_alub2 & m[4] & t[3]);
endmodule

//----------------------------------------------------------------------
module Dec_alu_preset(                                                  // Модуль формирования сигнала предустановки флагов и аргументов для АЛУ
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         grp_idx,                                              // Группа команд с индексной адресацией
    input         grp_shift,                                            // Группа команд сдвигов
    output        alu_preset                                            // Сигнал предустановки флагов и аргументов для АЛУ
);
    assign alu_preset = ((grp_idx | grp_shift) & m[4] & t[3]) |
                        (m[1] & t[4]);                                  // standard ALU cycle
endmodule

//----------------------------------------------------------------------
module Dec_seta_00(                                                     // Модуль формирования сигнала обнуления ALUA
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         alu_preset,                                           // Сигнал предустановки флагов и аргументов для АЛУ
    input         sel_rst_nmi_im1,                                      // Группа команд RST/NMI/IM 1
    output        seta_00                                               // Сигнал обнуления ALUA
);
    assign seta_00 = (pla[61] |                                         // LD
                      pla[87] |                                         // LD A,I/R
                      pla[17] |                                         // LD r/(HL),n
                      pla[81] |                                         // CPL
                      pla[82] |                                         // NEG
                      pla[25] |                                         // RLCA/RRCA/RLA/RRA
                      pla[70] |                                         // SHIFT
                      pla[67] |                                         // IN r,(C)
                      sel_rst_nmi_im1) & alu_preset;
endmodule

//----------------------------------------------------------------------
module Dec_imm(                                                         // Модуль формирования сигналов GRP_IMM16 и GRP_IMM
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         grp_idx_cb,                                           // Сигнал группы команд GRP_IDX_CB
    input         grp_imm8,                                             // Группа команд, читающих один байт непосредственных данных
    input         grp_idx,                                              // Группа команд с индексной адресацией
    input         idx_set,                                              // Набор команд с префиксом DD/FD
    output        grp_imm16,                                            // Группа команд, читающих два байта непосредственных данных
    output        grp_imm                                               // Группа команд, использующих непосредственную адресацию
);
    assign grp_imm16 = pla[7]  |                                        // LD dd,nn
                       pla[38] |                                        // LD A,(nn) / LD (nn),A
                       pla[30] |                                        // LD (nn),HL / LD HL,(nn)
                       pla[31] |                                        // LD (nn),dd / LD dd,(nn)
                       pla[29] |                                        // JP nn
                       pla[43] |                                        // JP cc,nn
                       pla[24] |                                        // CALL nn
                       pla[42] |                                        // CALL cc,nn
                       (pla[40] & idx_set) |                            // LD (ii+d),n
                       grp_idx_cb;                                      // IDX CB SET
    assign grp_imm = grp_imm16 | grp_imm8 | grp_idx;
endmodule

//----------------------------------------------------------------------
//
//              Модуль управления чтением/записью регистров
//
//----------------------------------------------------------------------
module Reg_readwrite(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [2:0]  reg_n,                                                // Трехбитный код регистровой пары
    input         sel_acc,                                              // Сигнал выбора аккумулятора по умолчанию
    input         req_flags,                                            // Сигнал работы с флагами
    input         grp_data16,                                           // Группа команд для работы с 16-битными данными
    input         grp_wrdata,                                           // Группа команд, записывающих данные в память
    input         grp_a_mem_io,                                         // Группа команд записи/чтения памяти/портов
    input         grp_offset_raw,                                       // Группа команд, работающих с относительной адресацией
    input         grp_block,                                            // Группа блочных команд
    input         grp_dst_af,                                           // Группа команд для работы с регистром-приемником AF
    input         add_sub_hl,                                           // Группа команд ADD/SUB HL
    input         grp_store16,                                          // Группа команд LD (nn),dd
    input         sel_rst_nmi_im1,                                      // Группа команд RST/NMI/IM 1
    input         sel_im2,                                              // Сигнал прерывания IM 2
    input         sel_reg_dst_r,                                        // Сигнал выбора регистра-приемника или IR
    input         sel_reg_src_r,                                        // Сигнал выбора регистра-источника или IR
    output        write_regh,                                           // Сигнал записи данных в старшую часть выбранного регистра
    output        write_regl,                                           // Сигнал записи данных в младшую часть выбранного регистра
    output        read_regh,                                            // Сигнал чтения данных из старшей части выбранного регистра
    output        read_regl                                             // Сигнал чтения данных из младшей части выбранного регистра
);
    wire grp_wr_reg16;

//----------------------------------------------------------------------
    assign grp_wr_reg16 = ((grp_data16 & ~grp_wrdata) |                 // LD dd,nn / LD dd,(nn) / ADD/SBC HL,dd
                           add_sub_hl |                                 // JP nn / JP cc,nn / JP (HL)
                           sel_rst_nmi_im1) &                           // RET / RET cc / RETN/RETI
                          ~grp_a_mem_io;                                // RST / POP dd / NMI / INT IM1/2

    assign write_regl = (sel_acc & req_flags) |                         // Save flags to F
                        (((grp_offset_raw & ~grp_block) | sel_im2) & m[3] & t[2]) | // Save low byte of index pointer
                        ((grp_data16 | grp_store16) & m[2] & t[3] & ~sel_im2) |     // LD (nn),dd
                        ((~(reg_n[1] & reg_n[2]) & reg_n[0]) & sel_reg_dst_r) |     // Save low destination register (L, E, C)
                        (grp_wr_reg16 & m[4] & t[3]);

    assign write_regh = (m[1] & t[2] & grp_dst_af) |                    // Save result to A
                        (m[4] & t[3] & grp_a_mem_io) |                  // Save data to A
                        (m[3] & t[5] & grp_offset_raw) |                // Save high byte of index pointer
                        ((pla[25] | pla[26] | pla[20] | pla[21] | grp_a_mem_io) & m[2] & t[1]) |
                        ((grp_data16 | grp_store16) & m[3] & t[3]) |
                        (((reg_n[1] & reg_n[2]) | ~reg_n[0]) & sel_reg_dst_r) | // Save high destination register
                        (grp_wr_reg16 & m[5] & t[3]);

    assign read_regl = (m[5] & t[1] & grp_data16) |
                       ((grp_store16 | add_sub_hl) & m[1] & t[4]) |     // LD (nn),dd / ADD/SBC HL,dd
                       ((grp_store16 | add_sub_hl) & m[4] & t[1]) |
                       (m[3] & t[1] & sel_im2) |
                       (m[2] & t[2]) |                                  // Load low byte of index pointer
                       (sel_acc & ~req_flags) |                         // Load flags from F
                       ((~(reg_n[1] & reg_n[2]) & reg_n[0]) & sel_reg_src_r); // Load low source register

    assign read_regh = ((pla[25] | pla[26] | pla[20] | pla[21]) & m[1] & t[4]) |
                       (m[4] & t[4]) |
                       ((t[1] | t[3]) & m[2] & sel_im2) |
                       (grp_data16 & m[4] & t[1]) |
                       ((grp_store16 | add_sub_hl) & m[5] & t[1]) |     // LD (nn),dd / ADD/SBC HL,dd
                       (m[3] & t[3] & grp_offset_raw) |                 // Load high byte of index pointer
                       (((reg_n[1] & reg_n[2]) | ~reg_n[0]) & sel_reg_src_r) | // Load high source register
                       sel_acc;                                         // Load A register by default
endmodule

//----------------------------------------------------------------------
//
//                   Модуль режима вычисления индекса
//
//----------------------------------------------------------------------
module Idx_mode(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input        grp_idx,                                               // Группа команд с индексной адресацией
    input        grp_offset_raw,                                        // Группа команд, работающих с относительной адресацией
    output reg   index_math                                             // Сигнал, определяющий режим вычисления индекса
);
    always @(negedge clk)                                               // RS-триггер для сигнала INDEX_MATH
    begin
        if (m[1] | m[4])                                                // В циклах M1 и M4 всегда сбрасывается
            index_math <= 0;
        else if ((grp_idx | grp_offset_raw) & m[2] & t[2])              // Для команд с индексной или относительной адресацией
            index_math <= 1;                                            // устанавливается в такте M2.T2
    end
endmodule

//----------------------------------------------------------------------
//
//           Модуль определяющий, влияет ли команда на флаги
//
//----------------------------------------------------------------------
module Dec_req_flags(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input        sel_acc,                                               // Сигнал выбора аккумулятора по умолчанию
    input        grp_dst_af,                                            // Группа команд для работы с регистром-приемником AF
    output reg   req_flags                                              // Сигнал, определяющий, влияет ли команда на флаги
);
    wire grp_flags;
    wire req_flags_set;

    assign grp_flags = pla[65] |                                        // ALU
                       pla[64] |                                        // ALU n
                       pla[70] |                                        // RLC/RRC/RL/RR/SLA/SRA/SLL/SRL
                       pla[72] |                                        // BIT
                       pla[89] |                                        // CCF
                       pla[92] |                                        // SCF
                       pla[66] |                                        // INC/DEC r/(HL)
                       pla[69] |                                        // ADD HL,dd
                       pla[68] |                                        // SBC HL,dd / ADC HL,dd
                       pla[67] |                                        // IN r,(C)
                       pla[91] |                                        // INI/OUTI/IND/OUTD / INIR/OTIR/INDR/OTDR
                       pla[11] |                                        // CPI/CPD/CPIR/CPDR
                       pla[18];                                         // LDI/LDD/LDIR/LDDR

    assign req_flags_set = (grp_flags | grp_dst_af) & m[1] & t[1];      // Устанавливается, если команда влияет на флаги

    always @(negedge clk)                                               // RS-триггер для сигнала REQ_FLAGS
    begin
        if (req_flags_set)                                              // Если команда из группы влияющей на флаги
            req_flags <= 1;                                             // по M1.T1 установить REQ_FLAGS
        else if (sel_acc)                                               // По SEL_ACC (M1.T3 или M4.T2) сбросить
            req_flags <= 0;
    end
endmodule

//----------------------------------------------------------------------
//
//           Модуль определяющий, на какие флаги влияет команда
//
//----------------------------------------------------------------------
module Dec_flags_groups(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         add_sub_hl,                                           // Группа команд сложения/вычитания с HL
    input         alu_preset,                                           // Сигнал предустановки флагов и аргументов для АЛУ
    input         req_alu_high,                                         // Запрос окончания фазы работы с младшим нибблом
    output        set_z_clr_pv,                                         // Сигнал предварительной установки флагов P/V, Z
    output        upd_p_low,                                            // Сигнал влияния на флаг P для младшего полубайта
    output        upd_pv_z_s                                            // Сигнал влияния на флаги P/V, Z, S
);
    wire grp_flags2;
    assign grp_flags2 = pla[65] |                                       // ALU
                        pla[64] |                                       // ALU n
                        pla[87] |                                       // LD A,I/R
                        pla[70] |                                       // RLC/RRC/RL/RR/SLA/SRA/SLL/SRL
                        pla[72] |                                       // BIT
                        pla[82] |                                       // NEG
                        pla[77] |                                       // DAA
                        pla[66] |                                       // INC/DEC r/(HL)
                        pla[68] |                                       // SBC HL,dd / ADC HL,dd
                        pla[60] |                                       // RRD/RLD
                        pla[26] |                                       // DJNZ e
                        pla[67] |                                       // IN r,(C)
                        pla[91] |                                       // INI/OUTI/IND/OUTD / INIR/OTIR/INDR/OTDR
                        pla[11];                                        // CPI/CPD/CPIR/CPDR
    assign upd_pv_z_s = ((~(pla[26] | pla[91] | pla[11]) & m[1] & t[2]) |
                         (pla[11] & m[3] & t[2]) |
                         ((pla[26] | pla[91]) & m[2] & t[1]) |
                         (add_sub_hl & m[4] & t[3])) & grp_flags2;
    assign set_z_clr_pv = alu_preset & grp_flags2;
    assign upd_p_low = req_alu_high & grp_flags2;
endmodule

//----------------------------------------------------------------------
//
//              Модуль декодера запроса регистра-источника
//
//----------------------------------------------------------------------
module Dec_reg_src(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         grp_m_hl,                                             // Группа команд с адресацией (HL)
    input         cb_set,                                               // Группа команд с префиксом CB
    output        sel_reg_src                                           // Запрос регистра-источника в тактах M1.T4 и М4.Т1
);
    wire grp_reg_src;
    assign grp_reg_src = pla[61] |                                      // LD
                         pla[65] |                                      // ALU
                         pla[64] |                                      // ALU n
                         pla[66] |                                      // INC/DEC r/(HL)
                         cb_set;                                        // Префикс CB
    assign sel_reg_src = (m[1] & t[4] & ~grp_m_hl & grp_reg_src) |      // Стандартный цикл выбора приемника-источника
                         ((grp_reg_src | pla[27]) & m[4] & t[1]);       // Запись регистра в память/порт
endmodule

//----------------------------------------------------------------------
//
//     Модуль декодера запроса регистра-источника/приемника или IR
//
//----------------------------------------------------------------------
module Dec_reg_src_dst_r(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [2:0]  reg_n,                                                // Трехбитный код регистровой пары
    input         sel_reg_src,                                          // Запрос регистра-источника
    input         sel_reg_dst,                                          // Запрос регистра-приемника
    output        sel_reg_src_r,                                        // Запрос регистра-источника или IR
    output        sel_reg_dst_r                                         // Запрос регистра-приемника или IR
);
    wire grp_r;
    assign grp_r = pla[4] & m[1] & t[4];                                // LD I/R,A / LD A,I/R
    assign sel_reg_src_r = (grp_r &  reg_n[1]) | sel_reg_src;           // LD A,I/R
    assign sel_reg_dst_r = (grp_r & ~reg_n[1]) | sel_reg_dst;           // LD I/R,A
endmodule

//----------------------------------------------------------------------
//
//        Модуль управления запретом чтения/записи внешней шины
//
//----------------------------------------------------------------------
module Dec_dis_bus(
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         grp_offset_raw,                                       // Группа команд, работающих с относительной адресацией
    input         grp_block,                                            // Группа блочных команд
    input         add_sub_hl,                                           // Группа команд сложения/вычитания с HL
    input         grp_imm16,                                            // Группа команд, читающих два байта непосредственных данных
    output        dis_bus                                               // Сигнал запрета чтения/записи шины
);
    assign dis_bus = ((grp_block | add_sub_hl) & (m[4] | m[5])) |
                     (((grp_offset_raw & ~grp_block) | pla[11] | pla[60]) & m[3] & ~grp_imm16); // CPI/CPD/CPIR/CPDR / RRD/RLD
endmodule

//----------------------------------------------------------------------
//
//              Модуль декодера запроса PC приемником
//
//----------------------------------------------------------------------
module Dec_pc_dst(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input         res,                                                  // Сигнал сброса
    input         grp_imm16,                                            // Группа команд, читающих два байта непосредственных данных
    input         grp_imm,                                              // Группа команд, использующих непосредственную адресацию
    output        sel_pc_dst                                            // Сигнал выбора PC приемником
);
    assign sel_pc_dst = (((grp_imm16 & m[3]) |
                          (grp_imm & m[2]) |
                          m[1]) &
                          t[1]) |
                          res;
endmodule

//----------------------------------------------------------------------
//
//              Модуль декодера запроса PC источником
//
//----------------------------------------------------------------------
module Dec_pc_src(
    input  [5:1]  m,                                                    // Машинные циклы
    input         grp_branch,                                           // Группа команд переходов
    input         grp_block,                                            // Группа блочных команд
    input         cond_done,                                            // Сигнал совпадения условия
    input         res_tclk,                                             // Сигнал сброса счета тактов T
    input         res_mclk,                                             // Сигнал сброса счета машинных циклов M
    input         grp_imm16,                                            // Группа команд, читающих два байта непосредственных данных
    input         grp_imm,                                              // Группа команд, использующих непосредственную адресацию
    output        sel_pc_src                                            // Сигнал выбора PC источником
);
    assign sel_pc_src = ((grp_imm & m[1]) |
                         (grp_imm16 & m[2]) |
                         (grp_block & m[3]) |
                         ((cond_done | ~grp_branch) & res_mclk)) &
                         res_tclk;
endmodule

//----------------------------------------------------------------------
//
//                     Модуль синхронизации АЛУ
//
//----------------------------------------------------------------------
module Alu_sync(
    input       clk,                                                    // Тактовый сигнал
    input [6:1] t,                                                      // Такты
    input [5:1] m,                                                      // Машинные циклы
    input [98:0] pla,                                                   // Шина ПЛМ
    input       add_sub_hl,                                             // Группа команд сложения/вычитания с HL
    input       grp_noalum1,                                            // Группа команд, не требующих АЛУ в цикле M1
    input       grp_offset_raw,                                         // Группа команд, работающих с относительной адресацией
    output      req_alu_high,                                           // Запрос окончания фазы работы с младшим нибблом
    output reg  sel_alu_low                                             // Фаза работы АЛУ с младшим нибблом
);
    wire start_alu;
    wire stop_alu;

    assign start_alu = (m[1] & t[4]) |                                  // Start standard ALU cycle
                       (m[2] & t[2]) |                                  // Start low byte add of index pointer
                       (m[3] & t[3]) |                                  // Start high byte add of index pointer
                       (m[4] & t[1]) |                                  // Start low byte of 16-bit add
                       (m[4] & t[4] & add_sub_hl);                      // Start high byte of 16-bit add

    assign stop_alu = (m[1] & t[5]) |                                   // Stop standard ALU cycle
                      (m[1] & t[1] & ~grp_noalum1) |                    // Stop standard ALU cycle
                      ((pla[11] | grp_offset_raw) & m[3] & t[1]) |      // Stop low byte add of index pointer
                      ((m[3] | m[4]) & t[4] & grp_offset_raw) |         // Stop high byte add of index pointer
                      ((m[4] | m[5]) & t[2] & add_sub_hl);              // Stop low/high byte of 16-bit add

    assign req_alu_high = sel_alu_low & stop_alu;                       // Сигнал запроса окончания фазы

    always @(negedge clk)                                               // RS-триггер выбора фазы работы АЛУ
    begin
        if (start_alu)
            sel_alu_low <= 1;
        else if (req_alu_high)
            sel_alu_low <= 0;
    end
endmodule

//----------------------------------------------------------------------
//
//               Модуль 16-битного регистра-инкрементера PCR
//
//----------------------------------------------------------------------
module PCR_unit(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input        res,                                                   // Сигнал сброса
    input        spec_res,                                              // Сигнал специального сброса
    input  [7:0] command,                                               // Регистр COMMAND
    input        sel_rst_nmi_im1,                                       // Группа команд RST/NMI/IM 1
    input        sel_im2,                                               // Сигнал прерывания IM 2
    input        grp_sp,                                                // Группа команд, работающих со стеком
    input        grp_block,                                             // Группа блочных команд
    input        grp_wrdata,                                            // Группа команд, записывающих данные в память
    input        grp_ldi_cpi,                                           // Группа команд LD(I/D)(R)/CP(I/D)(R)
    input        grp_offset_raw,                                        // Группа команд, работающих с относительной адресацией
    input        grp_m_hl,                                              // Группа команд с адресацией (HL)
    input        cond_done,                                             // Сигнал совпадения условия
    input        sel_pc_src,                                            // Сигнал выбора PC источником
    input        sel_pc_dst,                                            // Сигнал выбора PC приемником
    input        int_stop_pcr,                                          // Сигнал остановки счетчика PCR во время INT/HALT
    input        res_tclk,                                              // Сигнал сброса счета тактов T
    input        res_mclk,                                              // Сигнал сброса счета машинных циклов M
    input [15:0] pcrbus_out,                                            // Шина данных для чтения регистров
    output       write_pcr,                                             // Сигнал записи в PCR
    output reg   pcr_equal_one = 0,                                     // Сигнал того, что PCR = 0x0001
    output       join_rp,                                               // Сигнал обьединения банков регистров
    output [15:0] pcrbus_in,                                            // Шина данных для записи в регистры
    output reg [15:0] reg_pcr,                                          // Регистр PCR
    // === SAVESTATE PORTS ===
    input  [15:0] restore_pc,                                           // Значение PC для восстановления
    input         restore_en,                                           // Строб восстановления (активный высокий)
    output [15:0] save_pc                                               // Текущее значение PC для сохранения
);
    wire        decr_pcr;                                               // Сигнал управления инкрементом/декрементом PCR
    wire        stop_inc_pcr;                                           // Сигнал управления счетом/остановом PCR
    wire        read_pcr;                                               // Сигнал чтения PCR
    wire        rw_pc;                                                  // Сигнал чтения/записи PC
    wire        rw_ir;                                                  // Сигнал чтения/записи IR
    wire        clr_pcrbus_in;                                          // Сигнал очистки PCRBUS_IN
    wire        dis_high_inc_pcr;                                       // Сигнал выбора 16-битного/7-битного инкремента
    wire [15:0] inc_pcr;                                                // 16-битный инкрементер
    wire [15:0] buf_pcr;                                                // Буфер инкремента PCR

//----------------------------------------------------------------------
    Dec_decr_pcr dec_decr_pcr(                                          // Модуль управления инкрементом/декрементом PCR
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .command(command),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .sel_im2(sel_im2),
        .grp_sp(grp_sp),
        .grp_block(grp_block),
        .grp_wrdata(grp_wrdata),
        .grp_ldi_cpi(grp_ldi_cpi),
        .cond_done(cond_done),
        .decr_pcr(decr_pcr)                                             // Сигнал управления инкрементом/декрементом
    );

    Dec_stop_inc_pcr dec_stop_inc_pcr(                                  // Модуль управления счетом/остановом PCR
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .res(res),
        .res_tclk(res_tclk),
        .int_stop_pcr(int_stop_pcr),
        .stop_inc_pcr(stop_inc_pcr)                                     // Сигнал управления счетом/остановом
    );

    Dec_write_pcr dec_write_pcr(                                        // Декодер группы команд, запрашивающих запись в PCR
        .t(t),
        .m(m),
        .pla(pla),
        .grp_sp(grp_sp),
        .grp_block(grp_block),
        .grp_wrdata(grp_wrdata),
        .grp_offset_raw(grp_offset_raw),
        .grp_m_hl(grp_m_hl),
        .sel_im2(sel_im2),
        .sel_pc_dst(sel_pc_dst),
        .write_pcr(write_pcr)                                           // Сигнал записи в PCR
    );

    Dec_read_pcr dec_read_pcr(                                          // Модуль формирования сигнала чтения PCR
        .t(t),
        .m(m),
        .pla(pla),
        .grp_sp(grp_sp),
        .grp_block(grp_block),
        .sel_im2(sel_im2),
        .res_tclk(res_tclk),
        .res_mclk(res_mclk),
        .write_pcr(write_pcr),
        .read_pcr(read_pcr)                                             // Сигнал чтения PCR
    );

    assign rw_pc = sel_pc_dst | sel_pc_src;                             // Сигнал чтения/записи PC
    assign rw_ir = (t[2] | t[3]) & m[1];                                // Сигнал чтения/записи IR
    assign join_rp = ~(rw_pc | rw_ir);                                  // Сигнал обьединения банков регистров
    assign dis_high_inc_pcr = rw_ir;                                    // Признак 7-битного инкремента

    always @(posedge clk)                                               // Тактируется CLK
    begin
        if (decr_pcr)                                                   // Если строб декремента DECR_PCR
            pcr_equal_one <= (reg_pcr == 16'h0001);                     // записать в триггер новое значение
    end

    always @(negedge clk)                                               // По сигналу READ_PCR содержимое шины считывается в регистр
    begin
        if (restore_en)                                                 // === SAVESTATE: Приоритет восстановления ===
            reg_pcr <= restore_pc;                                      // Загрузить PC из restore_pc
        else if (read_pcr)                                              //
            reg_pcr <= pcrbus_out;                                      // Чтение PCR из регистрового файла
    end

    assign inc_pcr = stop_inc_pcr ? reg_pcr :                           // Если STOP_INC_PCR, то без инкремента
                     (decr_pcr ? (reg_pcr - 16'd1) :                    // Иначе, DECR_PCR, то REG_PCR - 1
                               (reg_pcr + 16'd1));                      // Иначе REG_PCR + 1

    assign buf_pcr = dis_high_inc_pcr ?                                 // Если DIS_HIGH_INC_PCR
                     {reg_pcr[15:7], inc_pcr[6:0]} :                    // то старшие 9 бит + младшие 7 бит инкрементера
                     inc_pcr;                                           // Иначе, 16 бит с инкрементера

    assign clr_pcrbus_in = ~write_pcr | res | (spec_res & m[1] & t[1]); // Если нет записи, сброс или специальный сброс
    assign pcrbus_in = clr_pcrbus_in ?                                  // Если активен CLR_PCRBUS_IN
                       0 :                                              // то на шину выдаем 0
                       buf_pcr;                                         // иначе значение BUF_PCR

    // === SAVESTATE: save_pc ===
    assign save_pc = reg_pcr;

endmodule

//----------------------------------------------------------------------
//
//             Модуль управления инкрементом/декрементом PCR
//
//----------------------------------------------------------------------
module Dec_decr_pcr(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0] command,                                               // Регистр COMMAND
    input        grp_sp,                                                // Группа команд, работающих со стеком
    input        grp_block,                                             // Группа блочных команд
    input        grp_wrdata,                                            // Группа команд, записывающих данные в память
    input        grp_ldi_cpi,                                           // Группа команд LD(I/D)(R)/CP(I/D)(R)
    input        sel_rst_nmi_im1,                                       // Группа команд RST/NMI/IM 1
    input        sel_im2,                                               // Сигнал прерывания IM 2
    input        cond_done,                                             // Сигнал совпадения условия
    output reg   decr_pcr                                               // Сигнал управления инкрементом/декрементом
);
    wire dec_cond;
    assign dec_cond = ((pla[16] | pla[14] | sel_rst_nmi_im1 | sel_im2) & m[1] & t[4]) |
                      (((grp_sp & ~cond_done) | grp_ldi_cpi) & (~pla[10]) & m[3] & t[3]) |
                      ((t[1] | t[3]) & m[4] & grp_block) |
                      (((grp_sp & grp_wrdata & m[4]) |
                        (grp_block & command[3] & m[3]) |
                        (((grp_block & command[3]) | sel_im2) & m[2])) & t[1]);
    always @(negedge clk)                                               // Задерживаем DECR_PCR на 1 такт
    begin
        decr_pcr <= dec_cond;
    end
endmodule

//----------------------------------------------------------------------
//
//             Модуль управления счетом/остановом PCR
//
//----------------------------------------------------------------------
module Dec_stop_inc_pcr(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input        res,                                                   // Сигнал сброса
    input        res_tclk,                                              // Сигнал сброса счета тактов T
    input        int_stop_pcr,                                          // Сигнал остановки счетчика PCR
    output       stop_inc_pcr                                           // Сигнал управления счетом/остановом
);
    reg stop_sphl;
    reg stop_int;

//----------------------------------------------------------------------
    always @(negedge clk)                                               // Триггер задержки останова для команд
    begin
        stop_sphl <= (pla[5] & t[4]) |                                  // LD SP,HL
                     (pla[10] & m[5] & t[3]);                           // EX (SP),HL
    end

    always @(negedge clk)                                               // RS-триггер маскирования останова
    begin
        if (res | t[1])                                                 // Если сброс или T1
            stop_int <= 0;                                              // то STOP_INT = 0
        else if (res_tclk)                                              // иначе, если последний Т-цикл
            stop_int <= 1;                                              // то STOP_INT = 1
    end

    assign stop_inc_pcr = stop_sphl | (stop_int & int_stop_pcr);        // Обьединяем все условия
endmodule

//----------------------------------------------------------------------
//
//              Модуль формирования сигнала записи в PCR
//
//----------------------------------------------------------------------
module Dec_write_pcr(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         grp_sp,                                               // Группа команд, работающих со стеком
    input         grp_block,                                            // Группа блочных команд
    input         grp_wrdata,                                           // Группа команд, записывающих данные в память
    input         grp_offset_raw,                                       // Группа команд, работающих с относительной адресацией
    input         grp_m_hl,                                             // Группа команд с адресацией (HL)
    input         sel_im2,                                              // Сигнал прерывания IM 2
    input         sel_pc_dst,                                           // Сигнал выбора PC приемником
    output        write_pcr                                             // Сигнал записи в PCR
);
    assign write_pcr = (m[1] & t[3]) |                                  // Save updated IR
                       (m[5] & t[4]) |
                       ((pla[10] | sel_im2 | grp_block) & m[2] & t[2]) | // Save updated pointer to HL / EX (SP),HL
                       ((~(grp_m_hl | grp_offset_raw) | grp_block) & m[4] & t[2]) | // Save decremented address to PC
                       ((grp_wrdata | sel_im2) & m[1] & t[5]) |          // INC/DEC dd / LD SP,HL / PUSH dd / RST/NMI/IM1/IM2
                       (grp_block & m[3] & t[2]) |                       // Save updated DE pointer
                       (~grp_wrdata & grp_sp & m[5] & t[2]) |            // RET / RET cc / RETN/RETI / POP dd
                       ((grp_block | grp_sp) & (m[3] | m[4]) & t[4]) |   // Save decremented counter/address
                       sel_pc_dst;
endmodule

//----------------------------------------------------------------------
//
//                 Модуль формирования сигнала чтения PCR
//
//----------------------------------------------------------------------
module Dec_read_pcr(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         grp_sp,                                               // Группа команд, работающих со стеком
    input         grp_block,                                            // Группа блочных команд
    input         sel_im2,                                              // Сигнал прерывания IM 2
    input         res_tclk,                                             // Сигнал сброса счета тактов T
    input         res_mclk,                                             // Сигнал сброса счета машинных циклов M
    input         write_pcr,                                            // Сигнал записи в PCR
    output        read_pcr                                              // Сигнал чтения PCR
);
    assign read_pcr = (((grp_sp & m[3]) | m[1]) & t[2]) |
                      (((grp_block & m[3]) | m[5]) & t[3]) |            // Load counter from BC
                      (m[1] & t[4]) |                                   // Read IR for LD A,I/R?
                      (((~(pla[10] | sel_im2) & m[2]) | m[1] | m[3] | res_mclk) & res_tclk) | // Read PC
                      write_pcr;
endmodule

//----------------------------------------------------------------------
//
//           Модуль выбора источника АЛУ для записи в регистр
//
//----------------------------------------------------------------------
module ALU_result_selector(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         grp_reg_dst,                                          // Группа команд, требующих регистр-приемник
    input         grp_dst_af,                                           // Группа команд для работы с регистром-приемником AF
    input         grp_offset_raw,                                       // Группа команд, работающих с относительной адресацией
    input         add_sub_hl,                                           // Группа команд сложения/вычитания с HL
    input         sel_rst_nmi_im1,                                      // Группа команд RST/NMI/IM 1
    input         sel_im1,                                              // Сигнал прерывания IM 1
    input         sel_im2,                                              // Сигнал прерывания IM 2
    output        sel_arga,                                             // Сигнал записи в регистр аргумента A
    output        sel_argb,                                             // Сигнал записи в регистр аргумента B
    output        sel_aluout                                            // Сигнал записи в регистр результата работы АЛУ
);
    assign sel_arga = (pla[98] & m[2] & t[1]) |                         // OUT (n),A / IN A,(n)
                      (sel_im1 & m[1] & t[5]) |                         // IM1 INT
                      (sel_im2 & m[3] & t[2]) |                         // IM2 INT
                      (sel_rst_nmi_im1 & m[5] & t[3]);                  // RST / NMI / IM1 INT

    assign sel_argb = (pla[57] & m[1] & t[4]) |                         // LD I/R,A
                      (sel_im2 & m[3] & t[3]) |                         // IM2 INT
                      (pla[60] & m[4] & t[1]) |                         // RRD / RLD
                      (sel_rst_nmi_im1 & m[4] & t[3]) |                 // RST / NMI / IM1 INT
                      (~sel_im2 & m[3] & t[1]);                         // IM2 INT

    assign sel_aluout = ((grp_reg_dst | grp_dst_af) & m[1] & t[2]) |
                        ((m[2] | m[5]) & t[1] & grp_offset_raw) |
                        (grp_offset_raw & m[3] & t[2]) |
                        (m[3] & t[5]) |
                        ((m[4] | m[5]) & t[3] & add_sub_hl);
endmodule

//----------------------------------------------------------------------
//
//                        Модуль флага S (SIGN)
//
//----------------------------------------------------------------------
module Flag_s_logic(
    input       clk,                                                    // Тактовый сигнал
    input [7:0] alu_out,                                                // Шина результата АЛУ
    input [7:0] fbus_out,                                               // Шина флагов
    input       upd_pv_z_s,                                             // Сигнал влияния на флаги
    input       load_flags,                                             // Сигнал сохранения текущих флагов
    output reg  flag_s                                                  // Триггер флага S
);
    always @(negedge clk)                                               // Триггер флага S
    begin
        if (load_flags)                                                 // Если сохранять флаги
            flag_s <= fbus_out[7];                                      // FLAG_S = FBUS_OUT[7]
        else if (upd_pv_z_s)                                            // Если устанавливать флаги
            flag_s <= alu_out[7];                                       // FLAG_S = ALUOUT[7]
    end
endmodule

//----------------------------------------------------------------------
//
//                        Модуль флага Z (ZERO)
//
//----------------------------------------------------------------------
module Flag_z_logic(
    input       clk,                                                    // Тактовый сигнал
    input [7:0] alu_out,                                                // Шина результата АЛУ
    input [7:0] fbus_out,                                               // Шина флагов
    input       upd_pv_z_s,                                             // Сигнал влияния на флаги
    input       set_z_clr_pv,                                           // Сигнал предварительной установки флагов
    input       load_flags,                                             // Сигнал сохранения текущих флагов
    output reg  flag_z                                                  // Триггер флага Z
);
    wire mux_z;                                                         // Мультиплексор входа триггера Z
    assign mux_z = (((alu_out == 0) && (flag_z == 1)) & upd_pv_z_s) |
                   (fbus_out[6] & load_flags);                          // Вход LOAD_FLAGS разрешает данные от FBUS_OUT[6]
    always @(negedge clk)                                               // Триггер флага Z
    begin
        if (set_z_clr_pv)                                               // Если предварительно устанавливать флаги
            flag_z <= 1;                                                // FLAG_Z = 1
        else if (upd_pv_z_s | load_flags)                               // Если LOAD_FLAGS или UPD_PV_Z_S
            flag_z <= mux_z;                                            // FLAG_Z = MUX_Z
    end
endmodule

//----------------------------------------------------------------------
//
//                        Модуль флага N (ADD/SUB)
//
//----------------------------------------------------------------------
module Flag_n_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0] fbus_out,                                              // Шина флагов
    input  [7:0] command,                                               // Регистр COMMAND
    input  [7:0] data_in,                                               // Внешняя шина данных
    input        index_math,                                            // Сигнал режима вычисления индекса
    input        grp_offset_raw,                                        // Группа команд, работающих с относительной адресацией
    input        alu_preset,                                            // Сигнал предустановки флагов
    input        load_flags,                                            // Сигнал сохранения текущих флагов
    output       flag_n,                                                // Флаг N
    output       flag_n2                                                // Промежуточный флаг сложения/вычитания
);
    reg  reg_n;                                                         // Триггер флага N
    wire grp_sub;                                                       // Группа команд, использующих вычитание
    wire mux_n;                                                         // Миксер входа триггера N
    wire ce0;                                                           // Условие тактирования CE0
    wire ce1;                                                           // Условие тактирования CE1
    wire block_sub;                                                     // Режим блокировки вычитания

    assign grp_sub = pla[75] |                                          // DEC r/(HL)
                     pla[76] |                                          // CP
                     pla[78] |                                          // SUB
                     pla[79] |                                          // SBC
                     pla[81] |                                          // CPL
                     pla[82] |                                          // NEG
                     pla[73] |                                          // RES
                     pla[26] |                                          // DJNZ e
                     pla[91] |                                          // INI/OUTI/IND/OUTD / INIR/OTIR/INDR/OTDR
                     pla[11];                                           // CPI/CPD/CPIR/CPDR

    assign ce0 = grp_offset_raw & m[2] & t[3];                          // Условие тактирования CE0
    assign ce1 = alu_preset & ~pla[77];                                 // Условие тактирования CE1 (кроме DAA)
    assign mux_n = (ce0 & data_in[7]) |                                 // Вход CE0 разрешает данные от DATA_IN[7]
                   (ce1 & ((pla[68] & ~command[3]) | grp_sub)) |        // Вход CE1 разрешает данные от операций вычитания
                   (load_flags & fbus_out[1]);                          // Вход LOAD_FLAGS разрешает данные от FBUS_OUT[1]

    always @(negedge clk)                                               // Триггер флага N
    begin
        if (ce0 | ce1 | load_flags)                                     // Если одно из условий активно
            reg_n <= mux_n;                                             // REG_N = MUX_N
    end

    assign block_sub = ~((t[3] | t[4] | t[5]) & m[3]) & index_math;     // Сигнал блокировки вычитания
    assign flag_n = ~block_sub & reg_n;                                 // FLAG_N
    assign flag_n2 = ~index_math & reg_n;                               // FLAG_N2
endmodule

//----------------------------------------------------------------------
//
//                        Модуль флага C (CARRY)
//
//----------------------------------------------------------------------
module Flag_c_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0] fbus_out,                                              // Шина флагов
    input  [7:0] hbus_data_in,                                          // Входящая шина данных с аргументом
    input        grp_offset_raw,                                        // Группа команд, работающих с относительной адресацией
    input        add_sub_hl,                                            // Группа команд сложения/вычитания с HL
    input        sh_left,                                               // Сдвиг влево
    input        sh_right,                                              // Сдвиг вправо
    input        carry_out,                                             // Флаг переноса из 4-го бита АЛУ
    input        set_daa_carry,                                         // Перенос во время команды DAA
    input        flag_h,                                                // Флаг полупереноса H
    input        flag_n2,                                               // Промежуточный флаг сложения/вычитания
    input        load_flags,                                            // Сигнал сохранения текущих флагов
    output reg   flag_c                                                 // Флаг C
);
    wire grp_c;                                                         // Группа команд влияющих на флаг C
    wire mux_c;                                                         // Миксер входа триггера C
    wire ce2;                                                           // Условие тактирования CE2
    wire ce3;                                                           // Условие тактирования CE3

    assign grp_c = pla[84] |                                            // ADD
                   pla[78] |                                            // SUB
                   pla[86] |                                            // OR
                   pla[88] |                                            // XOR
                   pla[76] |                                            // CP
                   pla[80] |                                            // ADC
                   pla[79] |                                            // SBC
                   pla[82] |                                            // NEG
                   pla[69] |                                            // ADD HL,dd
                   pla[68];                                             // SBC HL,dd / ADC HL,dd

    assign ce2 = (grp_c & m[1] & t[2]) |                                // Условие тактирования CE2
                 (grp_offset_raw & m[3] & t[2]) |
                 (add_sub_hl & m[4] & t[3]);

    assign ce3 = (pla[85] |                                             // AND
                  pla[89] |                                             // CCF
                  pla[92]) & m[1] & t[2];                               // SCF

    assign mux_c = (sh_right & hbus_data_in[0]) |                       // Вход SH_RIGHT
                   (sh_left  & hbus_data_in[7]) |                       // Вход SH_LEFT
                   (ce2 & (carry_out ^ flag_n2)) |                      // Вход CE2
                   (ce3 & ~flag_h) |                                    // Вход CE3
                   (load_flags & fbus_out[0]);                          // Вход LOAD_FLAGS

    always @(negedge clk)                                               // Триггер флага C
    begin
        if (set_daa_carry)                                              // Если установить C по SET_DAA_CARRY
            flag_c <= 1;                                                // FLAG_C = 1
        else if (sh_right | sh_left | ce2 | ce3 | load_flags)           // Иначе, если одно из условий активно
            flag_c <= mux_c;                                            // FLAG_C = MUX_C
    end
endmodule

//----------------------------------------------------------------------
//
//                       Модуль режима прерываний
//
//----------------------------------------------------------------------
module Im_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0] command,                                               // Регистр COMMAND
    input        sync_res,                                              // Сигнал синхронного сброса
    input        spec_res,                                              // Сигнал специального сброса
    input        reset_c,                                               // Сигнал сброса, синхронизированный с CLK
    input        empty_set,                                             // Сигнал пустого набора команд
    input        int_ack,                                               // Сигнал INT_ACK
    input        nmi_ack,                                               // Сигнал NMI_ACK
    input        halt,                                                  // Сигнал состояния останова
    input        grp_prefix,                                            // Группа команд, работающих с префиксами
    output       int_stop_pcr,                                          // Сигнал остановки счетчика PCR во время INT/HALT
    output       sel_im1,                                               // Сигнал прерывания IM 1
    output       sel_im2,                                               // Сигнал прерывания IM 2
    output       sel_nmi,                                               // Сигнал прерывания NMI
    output       sel_rst_nmi_im1,                                       // Группа команд RST/NMI/IM 1
    output       empty_set_req,                                         // Сигнал запроса пустого набора команд
    // === SAVESTATE PORTS ===
    input  [1:0] restore_im,                                            // Режим прерываний для восстановления
    input        restore_en,                                            // Строб восстановления (активный высокий)
    output       im_bit0_out,                                           // Бит 0 режима IM (для save_int)
    output       im_bit1_out                                            // Бит 1 режима IM (для save_int)
);
    reg  im_bit0;                                                       // Триггер бита-0 режима прерываний
    reg  im_bit1;                                                       // Триггер бита-1 режима прерываний
    wire cmd_im;                                                        // Сигнал команды IM0/1/2

//----------------------------------------------------------------------
    assign cmd_im = pla[96] & t[4] & m[1];                              // Сигнал команды IM0/1/2

    always @(negedge clk)                                               // Триггеры режима прерываний IM
    begin
        if (restore_en)                                                 // === SAVESTATE: Приоритет восстановления ===
        begin
            im_bit0 <= restore_im[0];                                   // Загрузить IM из restore_im
            im_bit1 <= restore_im[1];
        end
        else if (sync_res)                                              // Если сброс
        begin
            im_bit0 <= 1'b0;                                            // Сбросить триггеры режима IM
            im_bit1 <= 1'b0;
        end
        else if (cmd_im)                                                // Если сигнал команды IM0/1/2
        begin
            im_bit0 <= command[3];                                      // Установить режим IM согласно битам кода команды
            im_bit1 <= command[4];
        end
    end

//----------------------------------------------------------------------
    assign sel_im1 = ~im_bit0 & im_bit1 & int_ack & empty_set;          // Сигнал прерывания IM 1
    assign sel_im2 =  im_bit0 & im_bit1 & int_ack & empty_set;          // Сигнал прерывания IM 2
    assign sel_nmi = nmi_ack & empty_set;                               // Сигнал прерывания NMI
    assign sel_rst_nmi_im1 = (~empty_set & pla[56]) |                   // Если не режим останова декодера, то по RST n
                             sel_nmi | sel_im1;                         // иначе по INT_IM1 или NMI_ACK

    // Сигнал запроса пустого набора команд
    assign empty_set_req = (int_ack ? im_bit1 : spec_res) |
                           nmi_ack |
                           (~(t[2] & m[1] & reset_c & ~grp_prefix) & halt);

    assign int_stop_pcr = halt | int_ack | nmi_ack;                     // Остановка инкремента при прерывании или HALT

    // === SAVESTATE: im_bit outputs ===
    assign im_bit0_out = im_bit0;
    assign im_bit1_out = im_bit1;
endmodule

//----------------------------------------------------------------------
//
//                        Модуль прерываний
//
//----------------------------------------------------------------------
module Interrupt_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0] command,                                               // Регистр COMMAND
    input        res_tclk,                                              // Сигнал сброса счета тактов T
    input        res_mclk,                                              // Сигнал сброса счета машинных циклов M
    input        grp_prefix,                                            // Группа команд, работающих с префиксами
    input        res,                                                   // Сигнал сброса
    input        sync_res,                                              // Сигнал синхронного сброса
    input        p_int,                                                 // Порт запроса маскируемого прерывания
    input        nmi,                                                   // Порт запроса немаскируемого прерывания
    output       int_stb,                                               // Строб окончания текущей команды
    output       int_req,                                               // Сигнал запроса маскируемого прерывания
    output reg   int_ack,                                               // Сигнал подтверждения маскируемого прерывания
    output reg   nmi_ack,                                               // Сигнал подтверждения немаскируемого прерывания
    output reg   nmi_req,                                               // Сигнал запроса немаскируемого прерывания
    output reg   iff2,                                                  // Триггер разрешения прерывания IFF2
    // === SAVESTATE PORTS ===
    input  [1:0] restore_iff,                                           // Состояние IFF для восстановления {IFF2, IFF1}
    input        restore_en,                                            // Строб восстановления (активный высокий)
    output       iff1                                                   // Триггер разрешения прерывания IFF1 (для save_int)
);
    reg  int_c;                                                         // Триггер состояния порта запроса прерывания
    reg  nmi_res;                                                       // Триггер сброса запроса немаскируемого прерывания
    reg  nmi_smp1;                                                      // Триггер захвата фронта NMI 1
    reg  nmi_smp2;                                                      // Триггер захвата фронта NMI 2
    reg  nmi_smp3;                                                      // Триггер захвата фронта NMI 3
    reg  iff1_reg;                                                      // Триггер разрешения прерывания IFF1

//----------------------------------------------------------------------
    // === SAVESTATE: iff1 output ===
    assign iff1 = iff1_reg;

//----------------------------------------------------------------------
    // Триггеры подтверждения прерывания
    assign int_stb = res_tclk & res_mclk & ~grp_prefix & ~res;          // Строб конца команды

    always @(negedge clk)                                               // Триггеры подтверждения прерывания
    begin
        // Триггер INT
        if (sync_res)                                                   // Если сброс
            int_ack <= 0;                                               // обнулить триггер
        else if (int_stb)                                               // Иначе, если строб конца команды
            int_ack <= int_req;                                         // то триггер равен сигналу запроса

        // Триггер NMI
        if (sync_res)                                                   // Если сброс
            nmi_ack <= 0;                                               // обнулить триггер
        else if (int_stb)                                               // Иначе, если строб конца команды
            nmi_ack <= nmi_req;                                         // то триггер равен сигналу запроса
    end

//----------------------------------------------------------------------
    // Триггеры разрешения прерываний
    always @(posedge clk)
    begin
        // Триггер IFF2
        if (restore_en)                                                 // === SAVESTATE: Приоритет восстановления ===
            iff2 <= restore_iff[1];                                     // Загрузить IFF2
        else if (int_ack | res)                                         // Если сброс или подтверждение прерывания
            iff2 <= 0;                                                  // обнулить триггер
        else if (pla[97] & t[1] & m[1])                                 // Иначе, если команда DI/EI
            iff2 <= command[3];                                         // установить или обнулить

        // Триггер IFF1
        if (restore_en)                                                 // === SAVESTATE: Приоритет восстановления ===
            iff1_reg <= restore_iff[0];                                 // Загрузить IFF1
        else if (int_ack | nmi_ack | res)                               // Если сброс или подтверждение прерывания
            iff1_reg <= 0;                                              // обнулить триггер
        else if (pla[97] & t[1] & m[1])                                 // Иначе, если команда DI/EI
            iff1_reg <= command[3];                                     // установить или обнулить
        else if (pla[46] & t[2] & m[1])                                 // Иначе, если команда RETI/RETN
            iff1_reg <= iff2;                                           // IFF1 = IFF2
    end

    assign int_req = iff1_reg & int_c & ~nmi_req & ~pla[97];            // Запрос маскируемого прерывания

//----------------------------------------------------------------------
    // Триггеры запроса немаскируемого прерывания
    always @(posedge clk)
    begin
        // Триггер NMI_RES
        nmi_res <= nmi_ack | res;                                       // Если подтверждение или сброс
        nmi_smp1 <= nmi;                                                // Триггер для захвата фронта

        // Триггер NMI_REQ
        if (nmi_res)                                                    // Если сброс запроса
            nmi_req <= 0;                                               // сбросить
        else if (nmi_smp2 | (~nmi_smp3 & nmi))                          // Иначе, если зафиксирован фронт
            nmi_req <= 1;                                               // установить
    end

    always @(negedge clk)
    begin
        nmi_smp3 <= nmi;                                                // Триггер для захвата фронта по /CLK
        if (nmi_res)                                                    // Если сброс запроса
            nmi_smp2 <= 0;                                              // сбросить
        else                                                            // иначе
            nmi_smp2 <= ~nmi_smp1 & nmi;                                // установить при фронте 0->1
    end

//----------------------------------------------------------------------
    // Триггеры запроса маскируемого прерывания
    always @(posedge clk)
    begin
        int_c <= p_int;                                                 // Триггер состояния порта запроса
    end
endmodule

//----------------------------------------------------------------------
//
//                        Модуль останова HALT
//
//----------------------------------------------------------------------
module Halt_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input        reset_c,                                               // Сигнал сброса, синхронизированный с CLK
    input        sync_res,                                              // Сигнал синхронного сброса
    input        int_req,                                               // Сигнал запроса маскируемого прерывания
    input        nmi_req,                                               // Сигнал запроса немаскируемого прерывания
    input        int_stb,                                               // Строб окончания текущей команды
    input        spec_res,                                              // Сигнал специального сброса
    output       halt                                                   // Сигнал HALT
);
    wire int_nmi_req;                                                   // Запрос прерывания INT или NMI
    wire spec_res_pulse;                                                // Импульс установки специального сброса
    wire halt_pulse;                                                    // Одиночный импульс HALT
    reg  rs_halt;                                                       // Триггер базового сигнала HALT
    reg  m1_t3_del;                                                     // Триггер задержанного сигнала M1.T3
    reg  halt_del1;                                                     // Триггер задержки строба на полтакта
    reg  halt_del2;                                                     // Триггер задержки строба на один такт

//----------------------------------------------------------------------
    assign int_nmi_req = int_req | nmi_req;                             // Обьединенный запрос прерывания
    assign spec_res_pulse = t[2] & m[1] & reset_c;                      // Импульс установки специального сброса

    always @(negedge clk)                                               // Триггеры, работающие по /CLK
    begin
        // Триггер базового сигнала HALT
        if (pla[95] & int_stb & ~int_nmi_req)                           // Если команда HALT и нет запроса прерывания
            rs_halt <= 1;                                               // RS_HALT = 1
        else if (spec_res_pulse |                                       // Иначе, если условия сброса
                 spec_res |
                 sync_res |
                 (int_nmi_req & int_stb))
            rs_halt <= 0;                                               // RS_HALT = 0

        // Триггер задержки строба на один такт
        halt_del2 <= pla[95] & int_stb;
    end

    always @(posedge clk)                                               // Триггеры, работающие по CLK
    begin
        m1_t3_del <= t[3] & m[1];                                       // Триггер задержки M1.T3
        halt_del1 <= pla[95] & int_stb;                                 // Триггер задержки строба
    end

//----------------------------------------------------------------------
    assign halt_pulse = (halt_del2 | sync_res) &                        // Немаскируемый импульс
                        halt_del1 &
                        ~int_nmi_req;                                   // маскируется при запросе прерывания

    assign halt = (~(m1_t3_del & spec_res) &                            // Обрезаем задний фронт
                   rs_halt) |                                           // Смешиваем с базовым сигналом
                   halt_pulse;                                          // Добавляем импульс
endmodule

//----------------------------------------------------------------------
//
//                   Модуль управления запросом шины
//
//----------------------------------------------------------------------
module Bus_request_logic(
    input        clk,                                                   // Тактовый сигнал
    input        res,                                                   // Сигнал сброса
    input        res_tclk,                                              // Сигнал сброса счета T-циклов
    input        busrq,                                                 // Сигнал порта запроса доступа к шине
    output       t1_stall,                                              // Сигнал задержки цикла T1
    output       busack,                                                // Сигнал предоставления доступа к шине
    output reg   controls_z                                             // Сигнал перевода управляющих линий в z-состояние
);
    reg  busrq_c;                                                       // Триггер порта запроса шины
    reg  res_del;                                                       // Сигнал RES задержанный на один такт
    reg  res_tclk_del;                                                  // Сигнал задержанный на полтакта
    reg  reg_busack;                                                    // Триггер базового сигнала запроса шины

//----------------------------------------------------------------------
    always @(posedge clk)                                               // Триггеры, работающие по CLK
    begin
        busrq_c <= busrq;                                               // Триггер порта запроса шины
        res_tclk_del <= res_tclk;                                       // Триггер задержки
        controls_z <= reg_busack;                                       // Триггер управляющих линий
    end

    always @(negedge clk)                                               // Триггеры, работающие по /CLK
    begin
        res_del <= res;                                                 // Сигнал задержанный на один такт
        if (res)                                                        // Если сброс
            reg_busack <= 0;                                            // REG_BUSACK = 0
        else if (res_tclk | ~busrq_c)                                   // иначе, если последний Т-цикл или не активен
            reg_busack <= busrq_c;                                      // REG_BUSACK = BUSRQ_C
    end

//----------------------------------------------------------------------
    assign t1_stall = res_del | reg_busack;                             // Сигнал задержки цикла T1
    assign busack = reg_busack & ~res_tclk_del;                         // Сигнал предоставления доступа к шине
endmodule

//----------------------------------------------------------------------
//
//                        Модуль флага H (HALFCARRY)
//
//----------------------------------------------------------------------
module Flag_h_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input        grp_offset_raw,                                        // Группа команд, работающих с относительной адресацией
    input        add_sub_hl,                                            // Группа команд сложения/вычитания с HL
    input        alu_preset,                                            // Сигнал предустановки флагов
    input        carry_out,                                             // Флаг переноса из 4-го бита АЛУ
    input        req_alu_high,                                          // Запрос окончания фазы работы с младшим нибблом
    input        flag_c,                                                // Флаг C
    input        flag_n2,                                               // Промежуточный флаг сложения/вычитания
    output reg   flag_h                                                 // Флаг H
);
    wire set_halfcarry;                                                 // Сигнал установки флага полупереноса
    wire clear_halfcarry;                                               // Сигнал сброса флага полупереноса
    wire mux_h;                                                         // Миксер входа триггера H
    wire ce0;                                                           // Условие тактирования

    assign set_halfcarry = (pla[66] |                                   // INC/DEC
                            pla[72] |                                   // BIT
                            pla[81] |                                   // CPL
                            pla[85] |                                   // AND
                            pla[26] |                                   // DJNZ e
                            pla[91]) & alu_preset;                      // INI/OUTI/IND/OUTD

    assign clear_halfcarry = ((grp_offset_raw & m[2] & t[3]) | alu_preset) &
                             ~set_halfcarry & ~ce0;

    assign ce0 = ((pla[80] |                                            // ADC
                   pla[79] |                                            // SBC
                   pla[89] |                                            // CCF
                   pla[68]) & alu_preset) |                             // SBC HL,dd / ADD HL,dd
                  (grp_offset_raw & m[3] & t[3]) |
                  (add_sub_hl & m[4] & t[4]);

    assign mux_h = (ce0 & flag_c) |
                   (req_alu_high & (carry_out ^ flag_n2));

    always @(negedge clk)                                               // Триггер флага H
    begin
        if (set_halfcarry)                                              // Если установить H
            flag_h <= 1;                                                // FLAG_H = 1
        else if (clear_halfcarry)                                       // Иначе, если сбросить H
            flag_h <= 0;                                                // FLAG_H = 0
        else if (ce0 | req_alu_high)                                    // Иначе, если одно из условий
            flag_h <= mux_h;                                            // FLAG_H = MUX_H
    end
endmodule

//----------------------------------------------------------------------
//
//                    Модуль флага P/V (PARITY/OVERFLOW)
//
//----------------------------------------------------------------------
module Flag_pv_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0] alu_out,                                               // Шина результата АЛУ
    input  [7:0] fbus_out,                                              // Шина флагов
    input        upd_pv_z_s,                                            // Сигнал влияния на флаги
    input        set_z_clr_pv,                                          // Сигнал предварительной установки флагов
    input        upd_p_low,                                             // Сигнал влияния на флаг P для младшего полубайта
    input        load_flags,                                            // Сигнал сохранения текущих флагов
    input        iff2,                                                  // Состояние триггера IFF2
    input        pcr_equal_one,                                         // Сигнал того, что PCR = 0x0001
    input        grp_noalum1,                                           // Группа команд, не требующих АЛУ в цикле M1
    input        carry_6,                                               // Флаг переноса из 3-го бита АЛУ
    input        carry_out,                                             // Флаг переноса из 4-го бита АЛУ
    output reg   flag_pv                                                // Флаг P/V
);
    wire grp_v_if;                                                      // Группа команд, влияющих на флаг V
    wire sch_v;                                                         // Схема вычислений флага V
    wire sch_p;                                                         // Схема вычислений флага P
    wire sch_hp;                                                        // Схема вычисления флага получетности
    wire mux_pv;                                                        // Миксер входа триггера
    wire ce0;                                                           // Условие тактирования

    assign grp_v_if = pla[84] |                                         // ADD
                      pla[78] |                                         // SUB
                      pla[76] |                                         // CP
                      pla[80] |                                         // ADC
                      pla[79] |                                         // SBC
                      pla[82] |                                         // NEG
                      pla[87] |                                         // LD A,I/R
                      pla[66] |                                         // INC/DEC r/(HL)
                      pla[68];                                          // ADC HL,dd / SBC HL,dd

    assign sch_v = (carry_6 ^ carry_out) |                              // Флаг арифметического переполнения
                   (pla[87] & iff2);                                    // Флаг прерывания (LD A,I/R)

    assign sch_hp = flag_pv ^ alu_out[4] ^ alu_out[5] ^ alu_out[6];     // Вычисление четности для битов 4-6
    assign sch_p = sch_hp ^ alu_out[3] ^ alu_out[7];                    // Вычисление четности для битов 3 и 7

    // Условие тактирования (исчерпания счетчика для групповых команд)
    assign ce0 = ~pla[91] & grp_noalum1 & m[3] & t[4];

    assign mux_pv = (ce0 & ~pcr_equal_one) |
                    (load_flags & fbus_out[2]) |
                    (upd_pv_z_s & (grp_v_if ? sch_v : sch_p)) |
                    (upd_p_low & sch_hp);

    always @(negedge clk)                                               // Триггер флага P/V
    begin
        if (set_z_clr_pv)                                               // Если установить P/V
            flag_pv <= 1;                                               // FLAG_PV = 1
        else if (ce0 | load_flags | upd_pv_z_s | upd_p_low)             // Иначе, если одно из условий
            flag_pv <= mux_pv;                                          // FLAG_PV = MUX_PV
    end
endmodule

//----------------------------------------------------------------------
//
//                      Модуль одной секции АЛУ (1 бит)
//
//----------------------------------------------------------------------
module ALU_section(
    input        force_and,                                             // Признак форсирования операции AND
    input        force_or,                                              // Признак форсирования операции OR
    input        disable_carry,                                         // Признак запрета переноса
    input        a,                                                     // Бит операнда A
    input        b,                                                     // Бит операнда B
    input        c_in,                                                  // Вход переноса
    output       result,                                                // Бит результата
    output       c_out                                                  // Выход переноса
);
    wire pre_c;                                                         // Предварительный перенос

//----------------------------------------------------------------------
    assign pre_c = ((a | b) & c_in) |                                   // Вычисление предварительного переноса
                   (a & b) |
                   force_and;

    assign c_out = pre_c & ~disable_carry;                              // Вычисление переноса
    assign result = (a & b & c_in) |                                    // Вычисление бита результата
                    ((a | b | c_in) & (force_or | ~pre_c));
endmodule

//----------------------------------------------------------------------
//
//                      Модуль управления сдвигами
//
//----------------------------------------------------------------------
module Shift_logic(
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0]  command,                                              // Регистр COMMAND
    input  [3:0]  cond,                                                 // Шина условий/декодера типа сдвига
    input  [7:0]  hbus_data_in,                                         // Шина с входными данными
    input         flag_c,                                               // Флаг C
    input         req_alub2,                                            // Сигнал запроса ALUB2
    input         grp_shift,                                            // Группа команд сдвигов
    output        sh_bit0,                                              // Входящий бит-0 для сдвига влево
    output        sh_bit7,                                              // Входящий бит-7 для сдвига вправо
    output        sh_left,                                              // Сдвиг влево
    output        sh_right                                              // Сдвиг вправо
);
    assign sh_left  = req_alub2 & grp_shift & ~command[3];              // Сдвиг влево
    assign sh_right = req_alub2 & grp_shift &  command[3];              // Сдвиг вправо

    assign sh_bit0 = cond[0] ?                                          // RLC
                     hbus_data_in[7] :
                     ((flag_c | ~cond[1]) & ~cond[2]);                  // RL / SLA

    assign sh_bit7 = (hbus_data_in[0] | ~cond[0]) &                     // RRC
                     (flag_c          | ~cond[1]) &                     // RR
                     (hbus_data_in[7] | ~cond[2]) &                     // SRA
                     ~cond[3];                                          // SRL
endmodule

//----------------------------------------------------------------------
//
//                Модуль двоично-десятичной коррекции
//
//----------------------------------------------------------------------
module DAA_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [6:1]  t,                                                    // Такты
    input  [7:0]  fbus_out,                                             // Шина флагов
    input  [7:0]  alua,                                                 // Регистр аргумента ALUA
    input         sel_nmi,                                              // Сигнал прерывания NMI
    output [7:0]  daa_data,                                             // Слагаемое для коррекции или вектор
    output        set_daa_carry                                         // Перенос во время команды
);
    reg  carry;                                                         // Триггер флага переноса
    reg  halfcarry;                                                     // Триггер флага полупереноса
    wire over9;                                                         // Сигнал того, что число больше 9
    wire over99;                                                        // Сигнал того, что число больше 99
    wire line06;                                                        // Сигнал активации младшего ниббла константы
    wire line60;                                                        // Сигнал активации старшего ниббла константы
    wire cycle_daa;                                                     // Сигнал активного цикла
    wire cycle_nmi;                                                     // Сигнал активного цикла прерывания

//----------------------------------------------------------------------
    always @(negedge clk)                                               // Зафиксировать флаги в такте чтения
    begin
        if (t[3])
        begin
            carry     <= fbus_out[0];
            halfcarry <= fbus_out[4];
        end
    end

    assign cycle_daa = t[4] & pla[77];                                  // Активный цикл для команды
    assign cycle_nmi = t[5] & sel_nmi;                                  // Активный цикл для прерывания
    assign over9  = (alua[1] | alua[2]) & alua[3];                      // Сигнал аргумента больше 9
    assign over99 = ((over9 & alua[4]) | alua[5] | alua[6]) & alua[7];  // Сигнал аргумента больше 99
    assign line06 = ((over9  | halfcarry) & cycle_daa) | cycle_nmi;     // Активация младшего полубайта
    assign line60 = ((over99 | carry)     & cycle_daa) | cycle_nmi;     // Активация старшего полубайта
    assign daa_data = (8'h06 & {8{line06}}) |                           // Формирование константы коррекции
                      (8'h60 & {8{line60}});
    assign set_daa_carry = line60 & cycle_daa;                          // Перенос во время команды
endmodule

//----------------------------------------------------------------------
//
//                            Модуль АЛУ
//
//----------------------------------------------------------------------
module ALU_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0] hbus_out,                                              // Шина данных для чтения регистров
    input  [7:0] fbus_out,                                              // Шина данных для чтения флагов
    input  [7:0] data_in,                                               // Внешняя шина данных (ввод)
    input  [7:0] data_out,                                              // Шина данных (вывод)
    input  [7:0] command,                                               // Регистр COMMAND
    input  [3:0] cond,                                                  // Шина условий/декодера типа сдвига
    input        wr,                                                    // Сигнал записи
    input        sel_data_read,                                         // Сигнал чтения данных с внешней шины
    input        read_regh,                                             // Сигнал чтения старшей части регистра
    input        read_regl,                                             // Сигнал чтения младшей части регистра
    input        load_flags,                                            // Сигнал сохранения текущих флагов
    input        req_flags,                                             // Сигнал работы с флагами
    input        grp_noalum1,                                           // Группа команд, не требующих АЛУ в цикле M1
    input        grp_shift,                                             // Группа команд сдвигов
    input        grp_reg_dst,                                           // Группа команд, требующих регистр-приемник
    input        grp_dst_af,                                            // Группа команд для работы с регистром-приемником
    input        grp_offset_raw,                                        // Группа команд, работающих с относительной адресацией
    input        grp_idx,                                               // Группа команд с индексной адресацией
    input        add_sub_hl,                                            // Группа команд сложения/вычитания с HL
    input        cb_set,                                                // Набор команд с префиксом
    input        sel_nmi,                                               // Сигнал прерывания
    input        sel_rst_nmi_im1,                                       // Группа команд
    input        sel_im1,                                               // Сигнал прерывания
    input        sel_im2,                                               // Сигнал прерывания
    input        iff2,                                                  // Состояние триггера
    input        pcr_equal_one,                                         // Сигнал того, что счетчик равен 1
    input        index_math,                                            // Сигнал режима вычисления индекса
    input        sel_acc,                                               // Сигнал выбора аккумулятора
    input        sel_mask,                                              // Сигнал генерации маски
    output       flag_z,                                                // Флаг нуля
    output [7:0] hbus_in,                                               // Шина данных для записи в регистры, старшая часть
    output [7:0] fbus_in,                                               // Шина данных для записи в регистры, младшая часть
    output [7:0] alu_out                                                // Текущее состояние результата
);
    wire [7:0]  hbus_data_in;                                           // Входные данные шины
    wire [7:0]  alubus_in;                                              // Входящая шина для получения аргументов
    wire [7:0]  alubus_out;                                             // Выходящая шина для чтения результата
    reg  [7:0]  alua;                                                   // Регистр аргумента
    reg  [7:0]  alub;                                                   // Регистр аргумента
    wire [3:0]  operand_a;                                              // Операнд A
    wire [3:0]  operand_b;                                              // Операнд B
    wire [3:0]  operand_b_mux;                                          // Операнд B (мультиплексор)
    reg  [3:0]  alu_low;                                                // Регистр фиксации младшей части
    wire [7:0]  daa_data;                                               // Слагаемое для коррекции
    wire        req_alua;                                               // Сигнал запроса
    wire        req_alub1;                                              // Сигнал запроса
    wire        req_alub2;                                              // Сигнал запроса
    wire        alu_preset;                                             // Сигнал предустановки
    wire        seta_00;                                                // Сигнал обнуления
    wire        sel_arga;                                               // Сигнал записи аргумента
    wire        sel_argb;                                               // Сигнал записи аргумента
    wire        sel_aluout;                                             // Сигнал записи результата
    wire        alubus_to_alua;                                         // Сигнал записи в регистр
    wire        alubus_to_alub;                                         // Сигнал записи в регистр
    wire        dis_hbus;                                               // Сигнал запрета трансляции
    wire        sel_hbus_alubus;                                        // Сигнал трансляции
    wire        carry_4;                                                // Флаг переноса из 0-го бита
    wire        carry_5;                                                // Флаг переноса из 1-го бита
    wire        carry_6;                                                // Флаг переноса из 3-го бита
    wire        carry_out;                                              // Флаг переноса из 4-го бита
    wire        carry_in;                                               // Входящий перенос
    reg         reg_force_and;                                          // Триггер форсирования операции
    reg         reg_force_or;                                           // Триггер форсирования операции
    reg         reg_disable_carry;                                      // Триггер запрета переноса
    wire        force_and;                                              // Форсировать операции
    wire        force_or;                                               // Форсировать операции
    wire        disable_carry;                                          // Запретить перенос
    wire [7:0]  alu_res;                                                // Мультиплексор выбора источника
    wire        sel_alu_low;                                            // Фаза работы с младшим нибблом
    wire        req_alu_high;                                           // Запрос окончания фазы
    wire        sh_left;                                                // Сдвиг влево
    wire        sh_right;                                               // Сдвиг вправо
    wire        set_daa_carry;                                          // Перенос во время команды
    wire        flag_c;                                                 // Флаг переноса
    wire        flag_n;                                                 // Флаг сложения/вычитания
    wire        flag_pv;                                                // Флаг четности/переполнения
    wire        flag_h;                                                 // Флаг полупереноса
    wire        flag_s;                                                 // Флаг знака
    wire        flag_n2;                                                // Промежуточный флаг
    reg         flag_3_res;                                             // Триггер результата для флага 3
    reg         flag_5_res;                                             // Триггер результата для флага 5
    wire        set_z_clr_pv;                                           // Сигнал предварительной установки флагов
    wire        upd_p_low;                                              // Сигнал влияния на флаг
    wire        upd_pv_z_s;                                             // Сигнал влияния на флаги
    wire        setb_00;                                                // Сигнал записи константы
    wire        setb_vec;                                               // Сигнал загрузки вектора
    wire        sh_bit0;                                                // Входящий бит для сдвига
    wire        sh_bit7;                                                // Входящий бит для сдвига
    reg         req_flags_prev;                                         // Триггер предыдущей команды
    wire        rld_stb;                                                // Строб сдвига
    reg  [11:0] rld;                                                    // Регистр сдвига

//----------------------------------------------------------------------
    // Внутренние модули
    Alu_sync alu_sync(                                                  // Модуль синхронизации
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .add_sub_hl(add_sub_hl),
        .grp_noalum1(grp_noalum1),
        .grp_offset_raw(grp_offset_raw),
        .req_alu_high(req_alu_high),
        .sel_alu_low(sel_alu_low)
    );

    ALU_result_selector alu_result_selector(                            // Модуль выбора источника
        .t(t),
        .m(m),
        .pla(pla),
        .grp_reg_dst(grp_reg_dst),
        .grp_dst_af(grp_dst_af),
        .grp_offset_raw(grp_offset_raw),
        .add_sub_hl(add_sub_hl),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .sel_im1(sel_im1),
        .sel_im2(sel_im2),
        .sel_arga(sel_arga),
        .sel_argb(sel_argb),
        .sel_aluout(sel_aluout)
    );

    Dec_flags_groups dec_flags_groups(                                  // Модуль определения флагов
        .t(t),
        .m(m),
        .pla(pla),
        .add_sub_hl(add_sub_hl),
        .alu_preset(alu_preset),
        .req_alu_high(req_alu_high),
        .set_z_clr_pv(set_z_clr_pv),
        .upd_pv_z_s(upd_pv_z_s),
        .upd_p_low(upd_p_low)
    );

    Flag_s_logic flag_s_logic(                                          // Модуль флага
        .clk(clk),
        .alu_out(alu_out),
        .fbus_out(fbus_out),
        .upd_pv_z_s(upd_pv_z_s),
        .load_flags(load_flags),
        .flag_s(flag_s)
    );

    Flag_z_logic flag_z_logic(                                          // Модуль флага
        .clk(clk),
        .alu_out(alu_out),
        .fbus_out(fbus_out),
        .upd_pv_z_s(upd_pv_z_s),
        .set_z_clr_pv(set_z_clr_pv),
        .load_flags(load_flags),
        .flag_z(flag_z)
    );

    Flag_n_logic flag_n_logic(                                          // Модуль флага
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .fbus_out(fbus_out),
        .command(command),
        .data_in(data_in),
        .index_math(index_math),
        .grp_offset_raw(grp_offset_raw),
        .alu_preset(alu_preset),
        .load_flags(load_flags),
        .flag_n(flag_n),
        .flag_n2(flag_n2)
    );

    Flag_c_logic flag_c_logic(                                          // Модуль флага
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .fbus_out(fbus_out),
        .hbus_data_in(hbus_data_in),
        .grp_offset_raw(grp_offset_raw),
        .add_sub_hl(add_sub_hl),
        .sh_left(sh_left),
        .sh_right(sh_right),
        .carry_out(carry_out),
        .set_daa_carry(set_daa_carry),
        .flag_h(flag_h),
        .flag_n2(flag_n2),
        .load_flags(load_flags),
        .flag_c(flag_c)
    );

    Flag_h_logic flag_h_logic(                                          // Модуль флага
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .grp_offset_raw(grp_offset_raw),
        .add_sub_hl(add_sub_hl),
        .alu_preset(alu_preset),
        .carry_out(carry_out),
        .req_alu_high(req_alu_high),
        .flag_c(flag_c),
        .flag_n2(flag_n2),
        .flag_h(flag_h)
    );

    Flag_pv_logic flag_pv_logic(                                        // Модуль флага
        .clk(clk),
        .t(t),
        .m(m),
        .pla(pla),
        .alu_out(alu_out),
        .fbus_out(fbus_out),
        .upd_pv_z_s(upd_pv_z_s),
        .set_z_clr_pv(set_z_clr_pv),
        .upd_p_low(upd_p_low),
        .load_flags(load_flags),
        .iff2(iff2),
        .pcr_equal_one(pcr_equal_one),
        .grp_noalum1(grp_noalum1),
        .carry_6(carry_6),
        .carry_out(carry_out),
        .flag_pv(flag_pv)
    );

    Shift_logic shift_logic(                                            // Модуль управления сдвигами
        .pla(pla),
        .command(command),
        .cond(cond),
        .hbus_data_in(hbus_data_in),
        .flag_c(flag_c),
        .req_alub2(req_alub2),
        .grp_shift(grp_shift),
        .sh_bit0(sh_bit0),
        .sh_bit7(sh_bit7),
        .sh_left(sh_left),
        .sh_right(sh_right)
    );

    DAA_logic daa_logic(                                                // Модуль двоично-десятичной коррекции
        .clk(clk),
        .pla(pla),
        .t(t),
        .fbus_out(fbus_out),
        .alua(alua),
        .sel_nmi(sel_nmi),
        .daa_data(daa_data),
        .set_daa_carry(set_daa_carry)
    );

    Dec_req_alua dec_req_alua(                                          // Модуль формирования сигнала запроса
        .pla(pla),
        .t(t),
        .m(m),
        .sel_acc(sel_acc),
        .add_sub_hl(add_sub_hl),
        .grp_offset_raw(grp_offset_raw),
        .grp_idx(grp_idx),
        .sel_im2(sel_im2),
        .req_alua(req_alua)
    );

    Dec_req_alub1 dec_req_alub1(                                        // Модуль формирования сигнала запроса
        .t(t),
        .m(m),
        .add_sub_hl(add_sub_hl),
        .grp_idx(grp_idx),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .req_alub1(req_alub1)
    );

    Dec_req_alub2 dec_req_alub2(                                        // Модуль формирования сигнала запроса
        .t(t),
        .m(m),
        .pla(pla),
        .req_alub2(req_alub2)
    );

    Dec_seta_00 dec_seta_00(                                            // Модуль формирования сигнала
        .pla(pla),
        .alu_preset(alu_preset),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .seta_00(seta_00)
    );

    Dec_alu_preset dec_alu_preset(                                      // Модуль формирования сигнала
        .t(t),
        .m(m),
        .pla(pla),
        .grp_idx(grp_idx),
        .grp_shift(grp_shift),
        .alu_preset(alu_preset)
    );

//----------------------------------------------------------------------
    // Сдвиг регистра
    assign rld_stb = ((t[4] & ~command[3]) | t[2]) & m[3] & pla[60];    // Строб сдвига

    always @(negedge clk)                                               // Запись данных в сдвиговый регистр
    begin
        if (t[1] | t[3])                                                // Запись в циклах
            rld <= {alub[7:0], alua[3:0]};                              // Регистр сдвига
    end

//----------------------------------------------------------------------
    assign dis_hbus = (grp_shift & req_alub2) |                         // Сигнал запрета трансляции
                      (sel_im1 & m[1] & t[5]) |
                      sel_mask;

    assign sel_hbus_alubus = (req_alua | req_alub1 | req_alub2) &       // Сигнал выбора источника
                             ~dis_hbus;

    assign alubus_to_alua = req_alua & ~seta_00;                        // Сигнал загрузки в регистр
    assign alubus_to_alub = req_alub1 | req_alub2;                      // Сигнал загрузки в регистр

//----------------------------------------------------------------------
    // Входная шина обьединяет все входные данные
    assign hbus_data_in = hbus_out |                                    // источник данных из регистра
                          daa_data |                                    // источник данных коррекции
                          (sel_data_read ? data_in : 8'h00) |           // источник данных с внешней шины
                          ((t[5] & m[1] & sel_im2) ? command : 8'h00);  // источник вектора прерывания

    // Мультиплексор входной шины
    assign alubus_in = (sel_hbus_alubus ? hbus_data_in : 8'h00) |       // Обычное копирование данных
                       (sh_left  ? {hbus_data_in[6:0], sh_bit0} : 8'h00) | // Со сдвигом влево
                       (sh_right ? {sh_bit7, hbus_data_in[7:1]} : 8'h00) | // Со сдвигом вправо
                       (sel_mask ? (8'h01 << command[5:3]) : 8'h00);    // С генерацией маски

    // Сигнал записи константы
    assign setb_00 = (alu_preset & grp_offset_raw & ~cb_set) |
                     (pla[60] & m[4] & t[2]) |
                     (grp_offset_raw & m[3] & t[3]);

    assign setb_vec = t[2] & m[4] & sel_rst_nmi_im1 & ~sel_nmi;         // Сигнал загрузки вектора

    always @(negedge clk)                                               // Загрузка данных в регистры аргументов
    begin
        if (alubus_to_alua | rld_stb | seta_00)                         // Загрузка данных в регистр аргумента
            alua <= (alubus_to_alua ? alubus_in : 8'h00) |
                    (rld_stb ? {alua[7:4], rld[11:8]} : 8'h00);

        if (alubus_to_alub | rld_stb | setb_vec | setb_00)              // Загрузка данных в регистр аргумента
            alub <= (alubus_to_alub ? alubus_in : 8'h00) |
                    (rld_stb ? rld[7:0] : 8'h00) |
                    (setb_vec ? (sel_im1 ? 8'hFF: command) & 8'h38 : 8'h00);
    end

    assign operand_a = sel_alu_low ?                                    // Если работаем с младшим полубайтом
                       alua[3:0] :                                      // OPERAND_A = ALUA[3:0]
                       alua[7:4];                                       // иначе OPERAND_A = ALUA[7:4]

    assign operand_b_mux = sel_alu_low ?                                // Если работаем с младшим полубайтом
                           alub[3:0] :                                  // OPERAND_B_MUX = ALUB[3:0]
                           alub[7:4];                                   // иначе OPERAND_B_MUX = ALUB[7:4]

    assign operand_b = flag_n ?                                         // Если установлен флаг сложения/вычитания
                       ~operand_b_mux :                                 // инверсия
                       operand_b_mux;                                   // иначе без инверсии

//----------------------------------------------------------------------
    assign carry_in = flag_h ^ flag_n2;                                 // Входящий перенос

    always @(negedge clk)                                               // Выравнивание сигнала
    begin
        reg_force_and     <= pla[85] | pla[73] | pla[72];               // Признак форсирования операции
        reg_force_or      <= pla[86] | pla[74];                         // Признак форсирования операции
        reg_disable_carry <= pla[86] | pla[74] | pla[88];               // Признак запрета переноса
    end

    assign force_and     = reg_force_and     & ~index_math;             // Маскирование в режиме индекса
    assign force_or      = reg_force_or      & ~index_math;             // Маскирование в режиме индекса
    assign disable_carry = reg_disable_carry & ~index_math;             // Маскирование в режиме индекса

    ALU_section alu0(                                                   // Секция для 0-го бита
        .force_and(force_and),
        .force_or(force_or),
        .disable_carry(disable_carry),
        .a(operand_a[0]),
        .b(operand_b[0]),
        .c_in(carry_in),
        .result(alu_out[4]),
        .c_out(carry_4)
    );

    ALU_section alu1(                                                   // Секция для 1-го бита
        .force_and(force_and),
        .force_or(force_or),
        .disable_carry(disable_carry),
        .a(operand_a[1]),
        .b(operand_b[1]),
        .c_in(carry_4),
        .result(alu_out[5]),
        .c_out(carry_5)
    );

    ALU_section alu2(                                                   // Секция для 2-го бита
        .force_and(force_and),
        .force_or(force_or),
        .disable_carry(disable_carry),
        .a(operand_a[2]),
        .b(operand_b[2]),
        .c_in(carry_5),
        .result(alu_out[6]),
        .c_out(carry_6)
    );

    ALU_section alu3(                                                   // Секция для 3-го бита
        .force_and(force_and),
        .force_or(force_or),
        .disable_carry(disable_carry),
        .a(operand_a[3]),
        .b(operand_b[3]),
        .c_in(carry_6),
        .result(alu_out[7]),
        .c_out(carry_out)
    );

//----------------------------------------------------------------------
    always @(negedge clk)                                               // Регистр фиксации младшего полубайта
    begin
        if (sel_alu_low)
            alu_low <= alu_out[7:4];
    end

    assign alu_out[3:0] = alu_low;                                      // Младшие биты результата
    assign alu_res = (sel_aluout ? alu_out  : 8'h00) |                  // Выбор источника результата
                     (sel_arga   ? alua     : 8'h00) |
                     (sel_argb   ? alub     : 8'h00) |
                     ((wr & ~sel_arga & ~sel_argb) ? data_out : 8'h00);

    assign hbus_in = alu_res;                                           // Вывести результат на шину данных

//----------------------------------------------------------------------
    // Логика флагов 3 и 5
    wire scf_mode_stb = sel_acc & (pla[89] | pla[92]);                  // Строб установки флагов
    wire read_reg = read_regl | read_regh;                              // Сигнал чтения какого-либо регистра

    always @(negedge clk)                                               // Запоминаем потенциал шины для флагов
    begin
        if (sel_aluout |                                                // Если АЛУ выдает результат
            sel_data_read |                                             // или данные читаются
            read_reg |                                                  // или читается регистр
            scf_mode_stb)                                               // или команда, то
        begin
            flag_3_res <= (hbus_in[3]  & sel_aluout) |
                          (data_in[3]  & sel_data_read) |
                          (hbus_out[3] & read_reg) |
                          ((req_flags ? hbus_out[3] : (hbus_out[3] | fbus_out[3])) & scf_mode_stb);
            flag_5_res <= (hbus_in[5]  & sel_aluout) |
                          (data_in[5]  & sel_data_read) |
                          (hbus_out[5] & read_reg) |
                          ((req_flags ? hbus_out[5] : (hbus_out[5] | fbus_out[5])) & scf_mode_stb);
        end
    end

//----------------------------------------------------------------------
    // Финальное формирование флагов
    assign fbus_in[0] = flag_c;                                         // Флаг переноса
    assign fbus_in[1] = flag_n;                                         // Флаг сложения/вычитания
    assign fbus_in[2] = flag_pv;                                        // Флаг четности/переполнения
    assign fbus_in[3] = flag_3_res;                                     // Флаг 3
    assign fbus_in[4] = flag_h;                                         // Флаг полупереноса
    assign fbus_in[5] = flag_5_res;                                     // Флаг 5
    assign fbus_in[6] = flag_z;                                         // Флаг нуля
    assign fbus_in[7] = flag_s;                                         // Флаг знака
endmodule

//----------------------------------------------------------------------
//
//       Модуль декодера группы команд, заканчивающихся циклом
//
//----------------------------------------------------------------------
module Dec_m4_last_raw(
    input  [98:0] pla,                                                  // Шина ПЛМ
    output        grp_m4_last_raw                                       // Сигнал группы команд
);
    assign grp_m4_last_raw = pla[52] |                                  // ALU (HL)
                             pla[72] |                                  // BIT
                             pla[60] |                                  // RRD/RLD
                             pla[58] |                                  // LD r,(HL)
                             pla[59] |                                  // LD (HL),r
                             pla[40] |                                  // LD (HL),n
                             pla[38] |                                  // LD A,(nn) / (nn),A
                             pla[8]  |                                  // LD (BC/DE),A / A,(BC/DE)
                             pla[27] |                                  // IN r,(C) / OUT (C),r
                             pla[98] |                                  // OUT (n),A / IN A,(n)
                             pla[18] |                                  // LDI/LDD/LDIR/LDDR
                             pla[11] |                                  // CPI/CPD/CPIR/CPDR
                             pla[21] |                                  // INI/IND/INIR/INDR
                             pla[20];                                   // OUTI/OUTD/OTIR/OTDR
endmodule

//----------------------------------------------------------------------
//
//       Модуль декодера группы команд, не заканчивающихся циклом
//
//----------------------------------------------------------------------
module Dec_m1_not_last(
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         sel_im2,                                              // Сигнал прерывания
    output        grp_m1_not_last                                       // Сигнал группы команд
);
    assign grp_m1_not_last = pla[60] |                                  // RRD/RLD
                             pla[10] |                                  // EX (SP),HL
                             pla[7]  |                                  // LD dd,nn
                             pla[38] |                                  // LD A,(nn) / (nn),A
                             pla[30] |                                  // LD (nn),HL / HL,(nn)
                             pla[31] |                                  // LD (nn),dd / dd,(nn)
                             pla[26] |                                  // DJNZ e
                             pla[47] |                                  // JR e
                             pla[48] |                                  // JR NZ/Z/NC/C,e
                             pla[29] |                                  // JP nn
                             pla[43] |                                  // JP cc,nn
                             pla[24] |                                  // CALL nn
                             pla[42] |                                  // CALL cc,nn
                             pla[18] |                                  // LDI/LDD/LDIR/LDDR
                             pla[11] |                                  // CPI/CPD/CPIR/CPDR
                             pla[21] |                                  // INI/IND/INIR/INDR
                             pla[20] |                                  // OUTI/OUTD/OTIR/OTDR
                             sel_im2;
endmodule

//----------------------------------------------------------------------
//
//      Модуль декодера группы команд, заканчивающихся тактом
//
//----------------------------------------------------------------------
module Dec_m3_t3_last(
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         sel_im2,                                              // Сигнал прерывания
    output        grp_m3_t3_last                                        // Сигнал группы команд
);
    assign grp_m3_t3_last = pla[7]  |                                   // LD dd,nn
                            pla[38] |                                   // LD A,(nn) / (nn),A
                            pla[31] |                                   // LD (nn),dd / dd,(nn)
                            pla[30] |                                   // LD (nn),HL / HL,(nn)
                            pla[29] |                                   // JP nn
                            pla[43] |                                   // JP cc,nn
                            pla[20] |                                   // OUTI/OUTD/OTIR/OTDR
                            pla[21] |                                   // INI/IND/INIR/INDR
                            sel_im2;
endmodule

//----------------------------------------------------------------------
//
//       Модуль декодера группы команд, не заканчивающихся циклом
//
//----------------------------------------------------------------------
module Dec_m3_not_last_raw(
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         sel_im2,                                              // Сигнал прерывания
    input         grp_idx_cb,                                           // Сигнал группы команд
    output        grp_m3_not_last_raw                                   // Сигнал группы команд
);
    assign grp_m3_not_last_raw = pla[60] |                              // RRD/RLD
                                 pla[53] |                              // INC/DEC (HL)
                                 pla[38] |                              // LD A,(nn) / (nn),A
                                 pla[30] |                              // LD (nn),HL / HL,(nn)
                                 pla[31] |                              // LD (nn),dd / dd,(nn)
                                 pla[10] |                              // EX (SP),HL
                                 pla[24] |                              // CALL nn
                                 pla[42] |                              // CALL cc,nn
                                 pla[20] |                              // OUTI/OUTD/OTIR/OTDR
                                 pla[21] |                              // INI/IND/INIR/INDR
                                 grp_idx_cb |                           // IDX CB SET
                                 sel_im2;
endmodule

//----------------------------------------------------------------------
//
//    Модуль декодера группы команд, не заканчивающихся тактом
//
//----------------------------------------------------------------------
module Dec_m1_t4_not_last(
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         sel_im2,                                              // Сигнал прерывания
    input         sel_rst_nmi_im1,                                      // Группа команд
    output        grp_m1_t4_not_last                                    // Сигнал группы команд
);
    assign grp_m1_t4_not_last = pla[4]  |                               // LD I/R,A / A,I/R
                                pla[5]  |                               // LD SP,HL
                                pla[16] |                               // PUSH dd
                                pla[9]  |                               // INC/DEC dd
                                pla[26] |                               // DJNZ e
                                pla[45] |                               // RET cc
                                pla[20] |                               // OUTI/OUTD/OTIR/OTDR
                                pla[21] |                               // INI/IND/INIR/INDR
                                sel_im2 |
                                sel_rst_nmi_im1;
endmodule

//----------------------------------------------------------------------
//
//              Модуль управления машинными циклами
//
//----------------------------------------------------------------------
module MCycles_control(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         res,                                                  // Сигнал сброса
    input         grp_m_hl,                                             // Группа команд с адресацией
    input         grp_m4,                                               // Группа команд, требующих цикл
    input         grp_imm8,                                             // Группа команд, читающих байт
    input         grp_idx,                                              // Группа команд с индексной адресацией
    input         grp_offset_raw,                                       // Группа команд, работающих с относительной адресацией
    input         grp_m3_t3_last,                                       // Сигнал группы команд
    input         grp_m3_not_last_raw,                                  // Сигнал группы команд
    input         cond_done,                                            // Сигнал совпадения условия
    input         sel_im2,                                              // Сигнал прерывания
    output        res_mclk                                              // Сигнал сброса счета
);
    wire grp_m1_not_last;                                               // Сигнал группы команд
    wire grp_m4_last_raw;                                               // Сигнал группы команд

    Dec_m1_not_last dec_m1_not_last(                                    // Модуль декодера группы команд
        .pla(pla),
        .sel_im2(sel_im2),
        .grp_m1_not_last(grp_m1_not_last)
    );

    Dec_m4_last_raw dec_m4_last_raw(                                    // Модуль декодера группы команд
        .pla(pla),
        .grp_m4_last_raw(grp_m4_last_raw)
    );

    assign res_mclk = (~grp_m1_not_last &
                       ~grp_m_hl &
                       ~grp_m4 &
                       ~grp_imm8 &
                       m[1]) |
                      (~grp_m4 &
                       ~grp_idx &
                       ~grp_offset_raw &
                       grp_imm8 &
                       m[2]) |
                      (((~((grp_m4_last_raw & ~grp_m3_t3_last) | grp_m3_not_last_raw)) |
                        pla[0]) & m[3]) |
                      (grp_m4_last_raw & m[4]) |
                      m[5] |
                      cond_done |
                      res;
endmodule

//----------------------------------------------------------------------
//
//                  Модуль управления циклами
//
//----------------------------------------------------------------------
module TCycles_control(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         res,                                                  // Сигнал сброса
    input         grp_offset_raw,                                       // Группа команд
    input         grp_m3_t3_last,                                       // Сигнал группы команд
    input         grp_m3_not_last_raw,                                  // Сигнал группы команд
    input         grp_block,                                            // Группа блочных команд
    input         add_sub_hl,                                           // Группа команд сложения
    input         cond_done,                                            // Сигнал совпадения условия
    input         sel_im2,                                              // Сигнал прерывания
    input         sel_rst_nmi_im1,                                      // Группа команд
    output        res_tclk                                              // Сигнал сброса счета
);
    wire grp_m1_t4_not_last;                                            // Сигнал группы команд

    Dec_m1_t4_not_last dec_m1_t4_not_last(                              // Модуль декодера группы команд
        .pla(pla),
        .sel_im2(sel_im2),
        .sel_rst_nmi_im1(sel_rst_nmi_im1),
        .grp_m1_t4_not_last(grp_m1_t4_not_last)
    );

    assign res_tclk = ((m[2] |
                        (((grp_m3_not_last_raw & ~grp_m3_t3_last & ~grp_offset_raw & cond_done) |
                          grp_m3_t3_last) & m[3]) |
                        (~(add_sub_hl | grp_block | grp_offset_raw) & m[4]) |
                        (~pla[10] & m[5])) & t[3]) |
                      (((grp_m3_not_last_raw & ~grp_m3_t3_last & ~grp_offset_raw & m[3]) |
                        m[4]) & t[4] & ~grp_block) |
                      (~grp_m1_t4_not_last & m[1] & t[4]) |
                      (~pla[5] & ~pla[9] & t[5]) |
                      t[6] |
                      res;
endmodule

//----------------------------------------------------------------------
//
//               	  Модуль генератора циклов
//
//----------------------------------------------------------------------
module MCycles_generator(
    input       clk,                                                    // Тактовый сигнал
    input       grp_m_hl,                                               // Группа команд с адресацией
    input       grp_m4,                                                 // Группа команд, требующих цикл
    input       grp_imm8,                                               // Группа команд, читающих байт
    input       idx_set,                                                // Набор команд с префиксом
    input       res_tclk,                                               // Сигнал сброса счета
    input       res_mclk,                                               // Сигнал сброса счета
    output reg [5:1] m                                                  // Шина машинных циклов
);
    wire m2_skip;                                                       // Сигнал пропуска цикла

//----------------------------------------------------------------------
    assign m2_skip = ((~grp_imm8 & m[1]) | m[2]) &
                     (grp_m_hl ? (~idx_set) : grp_m4);

    always @(negedge clk)                                               // Триггеры циклов
    begin
        if (res_tclk)
        begin
            m[1] <= res_mclk;                                           // Триггер первого цикла
            m[2] <= m[1] & ~res_mclk & ~m2_skip;                        // Триггер второго цикла
            m[3] <= m[2] & ~res_mclk & ~m2_skip;                        // Триггер третьего цикла
            m[4] <= (m[3] | m2_skip) & ~res_mclk;                       // Триггер четвертого цикла
            m[5] <= m[4] & ~res_mclk;                                   // Триггер пятого цикла
        end
    end
endmodule

//----------------------------------------------------------------------
//
//                     Модуль генератора циклов
//
//----------------------------------------------------------------------
module TCycles_generator(
    input        clk,                                                   // Тактовый сигнал
    input  [5:1] m,                                                     // Машинные циклы
    input        t1_stall,                                              // Сигнал задержки цикла
    input        res_tclk,                                              // Сигнал сброса счета
    input        int_ack,                                               // Сигнал подтверждения прерывания
    input        grp_io,                                                // Сигнал группы ввода/вывода
    input        dis_bus,                                               // Сигнал запрета шины
    input        p_wait,                                                // Порт запроса ожидания
    output reg   int_t2_del,                                            // Импульс длиной 1 такт для торможения
    output [6:1] t                                                      // Шина тактов
);
    wire      set_t1;                                                   // Строб установки такта
    reg       t3_stall;                                                 // Триггер приостановки
    reg [6:1] reg_t = 0;                                                // Триггеры тактов

//----------------------------------------------------------------------
    // Логика останова
    always @(negedge clk)                                               // Триггеры переключаемые по спаду
    begin
        int_t2_del <= t[2] & m[1] & int_ack;                            // Импульс для торможения

        // Триггер приостановки цикла
        if (dis_bus)                                                    // Если запрет шины
            t3_stall <= 0;                                              // то сброс
        else
            t3_stall <= (((m[1] & int_ack) | grp_io) &
                         (t[2] | int_t2_del)) |
                        p_wait;
    end

//----------------------------------------------------------------------
    // Кольцевой счетчик тактов
    assign set_t1 = res_tclk | t1_stall;                                // Строб установки такта

    always @(negedge clk)                                               // Счетчик тактов
    begin
        reg_t[1] <= set_t1;                                             // Такт 1
        reg_t[2] <= t[1] & ~set_t1;                                     // Такт 2
        reg_t[3] <= (reg_t[3] | reg_t[2]) & ~t[3] & ~set_t1;            // Такт 3
        reg_t[4] <= t[3] & ~set_t1;                                     // Такт 4
        reg_t[5] <= t[4] & ~set_t1;                                     // Такт 5
        reg_t[6] <= t[5] & ~set_t1;                                     // Такт 6
    end

    assign t[1] = reg_t[1] & ~t1_stall;                                 // Сигнал такта замаскирован
    assign t[2] = reg_t[2];
    assign t[3] = reg_t[3] & ~t3_stall;                                 // Сигнал такта замаскирован
    assign t[4] = reg_t[4];
    assign t[5] = reg_t[5];
    assign t[6] = reg_t[6];
endmodule

//----------------------------------------------------------------------
//
//               Модуль формирования сигнала чтения данных
//
//----------------------------------------------------------------------
module Dec_data_read(
    input  [6:1]  t,                                                    // Такты
    input  [5:1]  m,                                                    // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input         idx_cb,                                               // Набор команд
    input         dis_bus,                                              // Сигнал запрета шины
    input         req_write,                                            // Сигнал запроса записи
    output        sel_data_read                                         // Сигнал чтения данных
);
//----------------------------------------------------------------------
    assign sel_data_read = ~(((idx_cb | pla[17]) & m[3]) | m[1]) &      // Кроме определенных циклов
                           ~dis_bus &                                   // Кроме цикла запрета
                           ~req_write &                                 // Кроме цикла записи
                           t[3];                                        // В определенном цикле
endmodule

//----------------------------------------------------------------------
//
//               Модуль формирования сигнала запроса записи
//
//----------------------------------------------------------------------
module Dec_req_write(
    input  [5:1]  m,                                                    // Машинные циклы
    input         sel_im2,                                              // Сигнал прерывания
    input         grp_block,                                            // Группа блочных команд
    input         grp_wrdata,                                           // Группа команд записи
    input         grp_offset_raw,                                       // Группа команд с относительной адресацией
    input         dis_bus,                                              // Сигнал запрета шины
    output        req_write                                             // Сигнал запроса записи
);
//----------------------------------------------------------------------
    assign req_write = ((sel_im2 & (m[2] | m[3])) |
                        (grp_block & m[3]) |
                        (grp_wrdata & (m[4] | m[5])) |
                        (grp_offset_raw & m[5])) &
                       ~dis_bus;
endmodule

//----------------------------------------------------------------------
//
//                     Модуль проверки условий
//
//----------------------------------------------------------------------
module Condition_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input  [7:0] command,                                               // Регистр
    input  [7:0] fbus_out,                                              // Шина флагов
    input  [2:0] reg_n,                                                 // Трехбитный код
    input        sel_acc,                                               // Сигнал выбора аккумулятора
    input        grp_ldi_cpi,                                           // Группа команд
    input        pcr_equal_one,                                         // Сигнал того, что счетчик равен 1
    input        flag_z,                                                // Флаг нуля
    output reg [3:0] cond,                                              // Шина условий
    output       cond_done                                              // Сигнал совпадения условия
);
    reg        condition;                                               // Регистр хранения совпадения
    wire [1:0] cond_code;                                               // Код условия

//----------------------------------------------------------------------
    assign cond_code = {(command[5] & ~pla[48]), command[4]};           // Двухбитный код условия

    always @(*)                                                         // Декодер условия / типа сдвига
    begin
        case (cond_code)
            2'b00 : cond = 4'b0001;                                     // Z / RLC
            2'b01 : cond = 4'b0010;                                     // C / RL
            2'b10 : cond = 4'b0100;                                     // PE / SLA
            2'b11 : cond = 4'b1000;                                     // M / SLL
        endcase
    end

    always @(negedge clk)                                               // Триггер фиксации совпадения
    begin
        if (sel_acc)
            condition <= (cond[0] & ~fbus_out[6]) |                     // Zero
                         (cond[1] & ~fbus_out[0]) |                     // Carry
                         (cond[2] & ~fbus_out[2]) |                     // Parity/overflow
                         (cond[3] & ~fbus_out[7]);                      // Sign
    end

    assign cond_done = ((condition ^ ~reg_n[0]) &
                        ((pla[45] & m[1]) |                             // RET cc
                         (pla[48] & m[2]) |                             // JR NZ/Z/NC/C,e
                         ((pla[43] | pla[42]) & m[3]))) |               // JP cc,nn / CALL cc,nn
                       (grp_ldi_cpi & pcr_equal_one & m[3]) |
                       (((pla[26] & m[2]) |
                         ((pla[91] | pla[11]) & m[3])) & flag_z);
endmodule

//----------------------------------------------------------------------
//
//                     		Модуль префиксов
//
//----------------------------------------------------------------------
module Prefix_logic(
    input        clk,                                                   // Тактовый сигнал
    input  [6:1] t,                                                     // Такты
    input  [5:1] m,                                                     // Машинные циклы
    input  [98:0] pla,                                                  // Шина ПЛМ
    input        grp_idx,                                               // Группа команд с индексной адресацией
    input        idx_cb,                                                // Сигнал набора команд
    input        empty_set_req,                                         // Сигнал запроса пустого набора
    input        res,                                                   // Сигнал сброса
    output reg   empty_set,                                             // Сигнал пустого набора
    output       base_set,                                              // Сигнал выбора базового набора
    output reg   ed_set,                                                // Сигнал выбора набора команд
    output reg   cb_set,                                                // Сигнал выбора набора команд
    output reg   idx_set,                                               // Сигнал выбора набора команд
    output       grp_idx_cb,                                            // Сигнал группы команд
    output       sel_mask                                               // Сигнал генерации маски
);
    wire   pref_stb;                                                    // Строб выбора набора команд
    wire   empty_set_req_stb;                                           // Строб триггера состояния
    reg    empty_set_req_del;                                           // Сигнал задержанный на полтакта

//----------------------------------------------------------------------
    assign pref_stb = (idx_cb & t[2] & m[3]) |                          // Строб для команд
                      (t[3] & m[1]);                                    // Строб для стандартных команд

    assign empty_set_req_stb = (idx_cb & t[1] & m[3]) |                 // Строб для команд
                               (t[2] & m[1]);                           // Строб для стандартных команд

    always @(negedge clk)                                               // Триггер, запоминающий состояние
    begin
        if (empty_set_req_stb)
            empty_set_req_del <= empty_set_req;
    end

    always @(posedge clk)                                               // Триггеры для наборов
    begin
        if (res)                                                        // Если сброс
        begin
            empty_set <= 1;                                             // Инициализация триггеров
            ed_set    <= 0;
            cb_set    <= 0;
        end
        else if (pref_stb)                                              // Иначе если строб
        begin
            empty_set <= empty_set_req_del;
            ed_set    <= pla[51];                                       // Набор команд
            cb_set    <= pla[44];                                       // Набор команд
        end
    end

    always @(posedge clk)                                               // Триггер для набора
    begin
        if (res)                                                        // Если сброс
            idx_set <= 0;                                               // инициализация триггера
        else if (pref_stb & ~pla[44])                                   // Иначе если строб и не активен префикс
            idx_set  <= pla[3];                                         // Набор команд
    end

//----------------------------------------------------------------------
    assign base_set = ~empty_set &                                      // Базовый набор команд
                      ~ed_set &                                         // если не активны другие
                      ~cb_set;                                          // и не установлен пустой набор

    assign grp_idx_cb = idx_cb | (cb_set & idx_set);                    // Сигнал группы команд

    assign sel_mask = (t[3] & m[1] & cb_set) |                          // Маска выбирается в такте
                      (t[1] & m[4] & cb_set & grp_idx);                 // Маска выбирается в такте
endmodule