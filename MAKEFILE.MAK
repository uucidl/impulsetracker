# Meant to be used with Borland's Make program
#
# For accurate dependency checking, use `make -a` to run it.
#
# This is what will make touching an include file like `SWITCH.INC` recompile everything.

OBJS=IT.OBJ IT_DISK.OBJ IT_DISPL.OBJ IT_EMS.OBJ IT_ERR.OBJ IT_F.OBJ IT_G.OBJ IT_H.OBJ \
IT_I.OBJ IT_K.OBJ IT_L.OBJ IT_M.OBJ IT_NET.OBJ IT_MSG.OBJ IT_MUSIC.OBJ IT_NET.OBJ IT_OBJ1.OBJ IT_PE.OBJ IT_S.OBJ \
IT_TUTE.OBJ IT_MMTSR.OBJ IT_MOUSE.OBJ IT_MDATA.OBJ IT_FOUR.OBJ IT_VESA.OBJ

IT.EXE: $(OBJS)
	TLINK /3 /s /v @source.lst

.ASM.OBJ:
#	TASM /Zi /m /uT310 /jSMART $*.asm
	TASM /m /uT310 /jSMART $*.asm



